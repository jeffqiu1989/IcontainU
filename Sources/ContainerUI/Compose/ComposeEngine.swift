import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Foundation
import Logging
import TerminalProgress

/// Orchestrates a compose project: creates the declared networks and volumes, then
/// creates+starts each service in dependency order. Every step reuses the existing
/// single-container machinery — `ContainerCreateEngine.create` runs the full
/// pull → init → create → start pipeline (with cancellation, mirrors, progress)
/// unchanged; this type only sequences calls and tags containers with project
/// labels so the group can be listed and torn down together.
enum ComposeEngine {
    private static let log = Logger(label: "icontainu.compose")

    private static let plugin = "container-network-vmnet"

    /// A service's started process, retained so a later `wait()` can read its
    /// exit code (which the container snapshot doesn't carry). Returned by `up`
    /// for every service it starts this call — new creates and idempotent
    /// restarts alike. A service left already-running (not restarted) has no
    /// fresh process and is omitted.
    struct StartedService: Sendable {
        let service: String
        let id: String
        let process: ClientProcess
    }

    /// Bring a project up. Idempotent: a service whose container already exists is
    /// started (if stopped) rather than recreated, so a second Up doesn't fail.
    ///
    /// `beginPhase` mirrors `ContainerCreateEngine.create`'s contract — it's called
    /// at each phase boundary with a label and returns the progress handler for that
    /// phase. Per-service phases are prefixed with the service name.
    ///
    /// Returns the processes started this call, so a caller doing `up wait` can
    /// `wait()` on a one-shot/init service's exit and capture its code.
    ///
    /// `onStarted` is invoked the instant each service's process starts, BEFORE
    /// the rest of Up (later services, the ~10s hosts-injection poll) runs. A
    /// one-shot that exits quickly would otherwise be gone before Up returns —
    /// and `wait()` on an already-exited container's init process hangs (a
    /// framework quirk) — so the caller must attach its `wait()` here, while the
    /// process is still live, not from the returned array afterward.
    @discardableResult
    static func up(
        project: String,
        parse: ComposeParseResult,
        onStarted: (@Sendable (StartedService) -> Void)? = nil,
        beginPhase: @escaping @Sendable (String) async -> ProgressUpdateHandler
    ) async throws -> [StartedService] {
        try await createNetworks(parse.declaredNetworks, project: project, beginPhase: beginPhase)
        try await createVolumes(parse.declaredVolumes, project: project, beginPhase: beginPhase)

        var started: [StartedService] = []
        let client = ContainerClient()
        for service in parse.orderedServices {
            guard let spec = parse.specs[service] else { continue }
            let id = spec.name ?? service

            // Idempotent: reuse an existing container instead of erroring — but
            // only when it belongs to THIS project. A container with the same name
            // owned by another project (e.g. two files both pinning
            // `container_name: db`) must not be silently adopted; fail loudly so the
            // user resolves the clash instead of one project hijacking the other's
            // container. A container with no project label is treated as a foreign
            // owner ("(none)") for the same reason.
            if let existing = try? await client.get(id: id) {
                let owner = existing.configuration.labels[ComposeFile.projectLabel]
                guard owner == project else {
                    throw ComposeError.containerNameConflict(
                        service: service, name: id, owner: owner ?? "(none)")
                }
                if existing.status != .running {
                    log.info("starting existing compose container", metadata: ["id": "\(id)"])
                    _ = await beginPhase("\(service): starting…")
                    let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
                    try await process.start()
                    let s = StartedService(service: service, id: id, process: process)
                    onStarted?(s)
                    started.append(s)
                }
                await injectHostsIncremental(project: project, client: client, startedService: service)
                continue
            }

            // Honor `depends_on: {condition: service_healthy}`: before creating
            // this service, wait for each healthy-gated dependency to pass its
            // healthcheck. A dependency was created+started in an earlier
            // iteration (topological order), so its container exists here.
            // `ComposeProbe` throws `.serviceUnhealthy` if one never becomes
            // healthy — the whole Up fails, but the dependency container is left
            // running so its logs can be inspected (see ComposeModel._up).
            // Gating only applies to about-to-create services: an already-running
            // dependent (idempotent reuse above) is left as-is.
            if let deps = parse.healthyDeps[service] {
                for dep in deps {
                    guard let hc = parse.healthchecks[dep] else { continue }
                    let depID = parse.specs[dep]?.name ?? dep
                    log.info("gating on healthy dependency", metadata: [
                        "service": "\(service)", "dependency": "\(dep)", "id": "\(depID)"])
                    let probe = ComposeProbe(spec: hc)
                    try await probe.waitUntilHealthy(
                        containerID: depID, service: service, dependency: dep,
                        beginPhase: beginPhase)
                }
            }

            try Task.checkCancellation()
            log.info("creating compose service", metadata: ["project": "\(project)", "service": "\(service)"])
            let (createdID, process) = try await ContainerCreateEngine.createRetainingProcess(spec: spec) { label in
                await beginPhase("\(service): \(label)")
            }
            let s = StartedService(service: service, id: createdID, process: process)
            onStarted?(s)
            started.append(s)
            await injectHostsIncremental(project: project, client: client, startedService: service)
        }

        // Wire up service discovery: the built-in DNS returns a wrong `28.0.0.x`
        // reserved address on macOS 26, so inject each service's real eth0 IP into
        // every project container's /etc/hosts. A just-started container needs a
        // moment before `list` reports its eth0 IP, so poll briefly until every
        // expected service has one before injecting — this makes Up produce a
        // complete hosts block rather than leaning on the model's poll loop to
        // fill in late-arriving services. Best-effort: after a few seconds we
        // inject whatever is ready (the poll loop still re-applies later).
        let expected = Set(parse.orderedServices)
        for attempt in 0..<10 {
            guard let all = try? await client.list(filters: ContainerListFilters.all.withoutMachines())
            else { break }
            let mappings = HostsInjector.mappings(containers: all)
            let ready = Set(mappings[project]?.endpoints.keys ?? [:].keys)
            if expected.isSubset(of: ready) || attempt == 9 {
                _ = await HostsInjector.inject(mappings)
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }

        return started
    }

    /// Start all stopped containers belonging to `project`. Unlike `up`, this
    /// never creates containers — it only resumes what already exists. Hosts are
    /// re-injected by the caller's `refresh()` once IPs settle.
    static func start(project: String) async throws {
        let client = ContainerClient()
        let all = try await client.list(filters: ContainerListFilters.all.withoutMachines())
        let mine = all.filter { $0.configuration.labels[ComposeFile.projectLabel] == project }
        for snapshot in mine where snapshot.status == .stopped {
            log.info("starting compose container", metadata: ["id": "\(snapshot.id)"])
            let process = try await client.bootstrap(id: snapshot.id, stdio: [nil, nil, nil])
            try await process.start()
        }
    }

    /// Stop all running containers belonging to `project` without deleting them.
    static func stop(project: String) async throws {
        let client = ContainerClient()
        let all = try await client.list(filters: ContainerListFilters.all.withoutMachines())
        let mine = all.filter { $0.configuration.labels[ComposeFile.projectLabel] == project }
        for snapshot in mine where snapshot.status == .running {
            log.info("stopping compose container", metadata: ["id": "\(snapshot.id)"])
            try await client.stop(id: snapshot.id)
        }
    }

    /// Collect service→IP mappings across all running containers and inject them
    /// into each project container's `/etc/hosts`. Returns the set of project names
    /// with at least one container that couldn't be written (degraded discovery).
    @discardableResult
    static func injectHosts(containers: [ContainerSnapshot]) async -> Set<String> {
        let mappings = HostsInjector.mappings(containers: containers)
        return await HostsInjector.inject(mappings)
    }

    /// Incremental hosts injection: after a service starts, publish every
    /// running project container's hostname → IP into all project containers'
    /// /etc/hosts BEFORE the next service starts. This lets a later one-shot
    /// (e.g. an init container) resolve its siblings during its own lifetime —
    /// the post-loop injection runs too late for one-shots that exit quickly.
    /// Waits briefly for the just-started service's own IP so its hostname is
    /// included in the block. Best-effort: on timeout, injects whatever is
    /// known (the model's 2s poll still re-applies later).
    private static func injectHostsIncremental(
        project: String, client: ContainerClient, startedService: String
    ) async {
        for _ in 0..<6 {
            guard let all = try? await client.list(filters: ContainerListFilters.all.withoutMachines()) else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let mappings = HostsInjector.mappings(containers: all)
            if mappings[project]?.endpoints[startedService] != nil {
                _ = await HostsInjector.inject(mappings)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // Fallback after the wait: inject whatever IPs are known.
        guard let all = try? await client.list(filters: ContainerListFilters.all.withoutMachines()) else { return }
        _ = await HostsInjector.inject(HostsInjector.mappings(containers: all))
    }

    /// Tear a project down: delete all of its containers (by project label), then
    /// optionally the declared networks/volumes. Container deletion is forced so a
    /// running service is stopped and removed in one step.
    static func down(
        project: String,
        record: ComposeProjectRecord?,
        removeVolumes: Bool,
        removeNetworks: Bool
    ) async throws {
        let client = ContainerClient()
        let all = try await client.list(filters: ContainerListFilters.all.withoutMachines())
        let mine = all.filter { $0.configuration.labels[ComposeFile.projectLabel] == project }

        for snapshot in mine {
            log.info("deleting compose container", metadata: ["id": "\(snapshot.id)"])
            try? await client.delete(id: snapshot.id, force: true)
        }

        if removeNetworks, let networks = record?.declaredNetworks {
            let netClient = NetworkClient()
            for network in networks {
                try? await netClient.delete(id: network)
            }
        }
        if removeVolumes, let volumes = record?.declaredVolumes {
            for volume in volumes {
                try? await ClientVolume.delete(name: volume)
            }
        }
    }

    // MARK: - Resource creation (idempotent)

    private static func createNetworks(
        _ names: [String], project: String,
        beginPhase: @Sendable (String) async -> ProgressUpdateHandler
    ) async throws {
        guard !names.isEmpty else { return }
        _ = await beginPhase("Creating networks…")
        let client = NetworkClient()
        let existing = Set(((try? await client.list()) ?? []).map(\.id))
        for name in names where !existing.contains(name) {
            try Task.checkCancellation()
            log.info("creating compose network", metadata: ["name": "\(name)"])
            let config = try NetworkConfiguration(name: name, mode: .nat, plugin: plugin)
            _ = try await client.create(configuration: config)
        }
    }

    private static func createVolumes(
        _ names: [String], project: String,
        beginPhase: @Sendable (String) async -> ProgressUpdateHandler
    ) async throws {
        guard !names.isEmpty else { return }
        _ = await beginPhase("Creating volumes…")
        let existing = Set(((try? await ClientVolume.list()) ?? []).map(\.name))
        for name in names where !existing.contains(name) {
            try Task.checkCancellation()
            log.info("creating compose volume", metadata: ["name": "\(name)"])
            _ = try await ClientVolume.create(name: name, labels: [ComposeFile.projectLabel: project])
        }
    }
}
