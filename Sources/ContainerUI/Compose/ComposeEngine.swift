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

    /// Bring a project up. Idempotent: a service whose container already exists is
    /// started (if stopped) rather than recreated, so a second Up doesn't fail.
    ///
    /// `beginPhase` mirrors `ContainerCreateEngine.create`'s contract — it's called
    /// at each phase boundary with a label and returns the progress handler for that
    /// phase. Per-service phases are prefixed with the service name.
    static func up(
        project: String,
        parse: ComposeParseResult,
        beginPhase: @escaping @Sendable (String) async -> ProgressUpdateHandler
    ) async throws {
        try await createNetworks(parse.declaredNetworks, project: project, beginPhase: beginPhase)
        try await createVolumes(parse.declaredVolumes, project: project, beginPhase: beginPhase)

        let client = ContainerClient()
        for service in parse.orderedServices {
            guard let spec = parse.specs[service] else { continue }
            let id = spec.name ?? service

            // Idempotent: reuse an existing container instead of erroring.
            if let existing = try? await client.get(id: id) {
                if existing.status != .running {
                    log.info("starting existing compose container", metadata: ["id": "\(id)"])
                    _ = await beginPhase("\(service): starting…")
                    let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
                    try await process.start()
                }
                continue
            }

            try Task.checkCancellation()
            log.info("creating compose service", metadata: ["project": "\(project)", "service": "\(service)"])
            _ = try await ContainerCreateEngine.create(spec: spec) { label in
                await beginPhase("\(service): \(label)")
            }
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
            let ready = Set(mappings[project]?.hosts.keys ?? [:].keys)
            if expected.isSubset(of: ready) || attempt == 9 {
                await HostsInjector.inject(mappings)
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Collect service→IP mappings across all running containers and inject them
    /// into each project container's `/etc/hosts`.
    static func injectHosts(containers: [ContainerSnapshot]) async {
        let mappings = HostsInjector.mappings(containers: containers)
        await HostsInjector.inject(mappings)
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
