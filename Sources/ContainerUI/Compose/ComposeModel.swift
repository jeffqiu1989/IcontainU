import ContainerAPIClient
import ContainerResource
import Foundation
import Observation
import TerminalProgress

/// One service's runtime status within a project view.
struct ComposeServiceStatus: Identifiable {
    /// Compose service name (also the container id, unless `container_name` was set).
    var service: String
    /// Runtime status, or nil when no container exists yet (project is down).
    var status: RuntimeStatus?
    /// The backing container's id, when one exists — used to open its logs
    /// directly from the project card. Nil when the service isn't created.
    var containerID: String?
    /// Last captured exit code for a stopped container, when known. The
    /// `ContainerSnapshot` carries only `RuntimeStatus` (no exit code), so this
    /// is populated only when an Up captured the code via `ClientProcess.wait()`
    /// — nil for containers that stopped outside a capturing Up.
    var exitCode: Int32?
    var id: String { service }
}

/// A project as shown in the Compose list: its services and their statuses,
/// assembled from the persisted record (the source of truth for membership) and
/// the live container list (the source of truth for status).
struct ComposeProjectView: Identifiable {
    var name: String
    var services: [ComposeServiceStatus]
    /// True when a persisted record backs this project (so it can be re-Upped /
    /// removed). False for a project discovered only from running containers, e.g.
    /// one started outside the app.
    var isStored: Bool
    var id: String { name }

    var runningCount: Int { services.filter { $0.status == .running }.count }
    var stoppedCount: Int { services.filter { $0.status == .stopped }.count }
    var totalCount: Int { services.count }
    /// A project with no running or stopped containers — fully down (or never upped).
    var isDown: Bool { runningCount == 0 && stoppedCount == 0 }
}

@Observable
@MainActor
final class ComposeModel {
    private(set) var projects: [ComposeProjectView] = []
    private(set) var pollError: String?
    private(set) var lastError: OperationError?

    /// Progress of an in-flight Up, and the project it's for.
    private(set) var upping: OperationProgress?
    private(set) var uppingProject: String?
    private var upTask: Task<Void, Never>?
    /// Guards `upping` against superseded tasks (same pattern as ContainersModel's
    /// `createGeneration`): a cancelled Up's server-side work can't be aborted, so
    /// its `defer` must not nil a newer task's bar.
    private var upGeneration = 0

    /// Projects currently mid-down, to disable their controls.
    private(set) var busyProjects: Set<String> = []

    /// Exit codes captured during a capturing Up (`compose_up` with `wait`).
    /// Keyed by container id. The `ContainerSnapshot` carries no exit code —
    /// only `RuntimeStatus` — so this map is the sole source of exit codes for
    /// `compose_status`. Cleared at the start of each capturing Up; entries
    /// persist across polls so a one-shot init container's exit code remains
    /// visible after it stops.
    private var capturedExitCodes: [String: Int32] = [:]

    /// Projects with at least one container we couldn't write `/etc/hosts` into
    /// (e.g. an image without `/bin/sh`), so service discovery may be degraded.
    /// Surfaced as a small warning badge on the project card.
    private(set) var hostsDegraded: Set<String> = []

    private let store = ComposeProjectStore.shared

    /// The captured exit code for a service's container, reported only for a
    /// stopped container. A running container has no exit code yet; a container
    /// that stopped outside a capturing Up isn't in the map (the framework
    /// retains no retroactive exit code), so this returns nil there.
    private func exitCode(for live: (status: RuntimeStatus, id: String)?) -> Int32? {
        guard let live, live.status == .stopped else { return nil }
        return capturedExitCodes[live.id]
    }

    func clearError() { lastError = nil }

    // Fresh client per use so a restarted apiserver is reconnected automatically.
    private var client: ContainerClient { ContainerClient() }

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Rebuild the project list = persisted records ∪ projects inferred from
    /// running containers' labels, merged by name.
    func refresh() async {
        store.load()
        do {
            let all = try await client.list(filters: ContainerListFilters.all.withoutMachines())
            // Group running containers by their project label.
            var byProject: [String: [String: (status: RuntimeStatus, id: String)]] = [:]
            for snapshot in all {
                guard let project = snapshot.configuration.labels[ComposeFile.projectLabel] else { continue }
                let service = snapshot.configuration.labels[ComposeFile.serviceLabel] ?? snapshot.id
                byProject[project, default: [:]][service] = (snapshot.status, snapshot.id)
            }

            var views: [ComposeProjectView] = []
            var seen = Set<String>()

            // Stored projects first — membership comes from the YAML so a down
            // project still lists all its services.
            for record in store.records {
                seen.insert(record.name)
                let serviceNames = Self.serviceNames(from: record.yaml)
                let live = byProject[record.name] ?? [:]
                let services = serviceNames.map {
                    ComposeServiceStatus(
                        service: $0, status: live[$0]?.status,
                        containerID: live[$0]?.id, exitCode: exitCode(for: live[$0]))
                }
                views.append(ComposeProjectView(name: record.name, services: services, isStored: true))
            }

            // Projects seen only in running containers (e.g. started via CLI).
            for (project, live) in byProject where !seen.contains(project) {
                let services = live.keys.sorted().map {
                    ComposeServiceStatus(
                        service: $0, status: live[$0]?.status,
                        containerID: live[$0]?.id, exitCode: exitCode(for: live[$0]))
                }
                views.append(ComposeProjectView(name: project, services: services, isStored: false))
            }

            projects = views.sorted { $0.name < $1.name }
            pollError = nil

            // Re-inject /etc/hosts so service discovery stays correct after a
            // container restart changes its IP. Throttled: skip when the
            // name→IP signature is unchanged since the last poll, so the steady
            // state does no `container exec` work.
            await refreshHosts(containers: all)
        } catch {
            pollError = error.localizedDescription
        }
    }

    /// Signature of the injected hosts block, cached so a no-op poll (IPs
    /// unchanged) doesn't re-run `container exec` on every container.
    private var lastHostsSignature: String = ""

    /// Re-inject service→IP into each project container's /etc/hosts when the
    /// mapping changed. Cheap when nothing changed (just a string compare).
    private func refreshHosts(containers: [ContainerSnapshot]) async {
        let mappings = HostsInjector.mappings(containers: containers)
        // A stable signature: project|service=ip sorted, so any IP change flips it.
        var parts: [String] = []
        for (project, mapping) in mappings.sorted(by: { $0.key < $1.key }) {
            for name in mapping.endpoints.keys.sorted() {
                let ep = mapping.endpoints[name]!
                // Fold every per-network IP in so a change on any network re-injects.
                let ips = ep.ipsByNetwork.sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }.joined(separator: ",")
                parts.append("\(project)|\(name)=\(ips)")
            }
        }
        let signature = parts.joined(separator: ";")
        guard signature != lastHostsSignature else { return }
        lastHostsSignature = signature
        hostsDegraded = await ComposeEngine.injectHosts(containers: containers)
    }

    /// Best-effort: extract service names from stored YAML for the down-state list.
    /// Falls back to empty on a parse failure (the live containers still show).
    private static func serviceNames(from yaml: String) -> [String] {
        guard let file = try? ComposeParser.parse(yaml: yaml) else { return [] }
        return file.services.keys.sorted()
    }

    // MARK: - Analyze (preview)

    /// Parse + lower for the import sheet's preview. Throws a `ComposeError` (or a
    /// Yams decode error) the sheet renders inline.
    func analyze(yaml: String, baseDirectory: URL?, projectName: String) throws -> ComposeParseResult {
        let (_, result) = try analyzeWithFile(
            yaml: yaml, baseDirectory: baseDirectory, projectName: projectName)
        return result
    }

    /// Parse + lower returning both the file (for override diffing) and the result.
    /// `${VAR}` references are interpolated from the compose file's `.env` before
    /// parsing; any undefined-variable warnings are merged into the result.
    func analyzeWithFile(yaml: String, baseDirectory: URL?, projectName: String) throws -> (ComposeFile, ComposeParseResult) {
        let interpolated = try EnvInterpolator.interpolate(yaml: yaml, baseDirectory: baseDirectory)
        let file = try ComposeParser.parse(yaml: interpolated.text)
        var result = try file.toSpecs(project: projectName, baseDirectory: baseDirectory)
        result.warnings = Self.mergeWarnings(result.warnings, interpolated.warnings)
        return (file, result)
    }

    /// Merge parse warnings with interpolation warnings, deduplicated and sorted
    /// (matching the ordering `toSpecs` already produces).
    private static func mergeWarnings(_ base: [String], _ extra: [String]) -> [String] {
        guard !extra.isEmpty else { return base }
        return Array(Set(base).union(extra)).sorted()
    }

    /// Whether a project with this name is already stored (warn before overwrite).
    func projectExists(_ name: String) -> Bool { store.exists(name) }

    // MARK: - Up

    func cancelUp() {
        upGeneration &+= 1
        upTask?.cancel()
        upping = nil
        uppingProject = nil
    }

    /// Persist the record, then bring the project up. Reuses the create engine per
    /// service; progress is shown on `upping`.
    func startUp(record: ComposeProjectRecord) {
        cancelUp()
        let generation = upGeneration
        upTask = Task { [weak self] in
            await self?._up(record: record, generation: generation, prebuiltParse: nil)
        }
    }

    /// Bring the project up using a pre-built parse result (from the import form).
    /// Skips re-parsing the YAML — the form has already applied user edits.
    func startUp(record: ComposeProjectRecord, parse: ComposeParseResult) {
        cancelUp()
        let generation = upGeneration
        upTask = Task { [weak self] in
            await self?._up(record: record, generation: generation, prebuiltParse: parse)
        }
    }

    private func _up(record: ComposeProjectRecord, generation: Int, prebuiltParse: ComposeParseResult?) async {
        lastError = nil

        // Re-parse to build specs (and re-validate relative binds against the saved
        // base directory). When a pre-built parse is provided (from the import form),
        // use it directly. Otherwise parse the stored YAML, applying any stored
        // service overrides before lowering to specs.
        let parse: ComposeParseResult
        if let prebuilt = prebuiltParse {
            parse = prebuilt
        } else {
            do {
                let interpolated = try EnvInterpolator.interpolate(
                    yaml: record.yaml, baseDirectory: record.baseDirectory)
                var file = try ComposeParser.parse(yaml: interpolated.text)
                if let overrides = record.serviceOverrides, !overrides.isEmpty {
                    file = file.applyOverrides(overrides)
                }
                parse = try file.toSpecs(project: record.name, baseDirectory: record.baseDirectory)
            } catch {
                lastError = .from("Failed to parse compose file", error: error)
                return
            }
        }

        // Persist before starting so a project that partially comes up is still
        // listed and can be torn down.
        do {
            try store.save(record)
        } catch {
            lastError = .from("Failed to save project", error: error)
            return
        }

        let progress = OperationProgress(phaseLabel: String(localized: "Starting \(record.name)…"))
        guard upGeneration == generation else { return }
        upping = progress
        uppingProject = record.name
        defer {
            if upGeneration == generation {
                upping = nil
                uppingProject = nil
            }
        }

        let progressHandler: ProgressUpdateHandler = { [weak progress] events in
            await progress?.apply(events)
        }
        let coordinator = ProgressTaskCoordinator()

        do {
            try await ComposeEngine.up(project: record.name, parse: parse) {
                [weak self, progress, progressHandler] label in
                await self?.beginUpPhase(
                    label, coordinator: coordinator, progress: progress,
                    progressHandler: progressHandler) ?? { _ in }
            }
            await coordinator.finish()
            // Up already injected /etc/hosts; reset the signature so the next
            // poll re-checks (and re-injects if any service came up late).
            lastHostsSignature = ""
            await refresh()
        } catch {
            await coordinator.finish()
            guard upGeneration == generation else { return }
            guard !error.isCancellation else { return }
            // A health-check gate failure is surfaced with a pointer to the
            // dependency's logs: the dependency container is left running (Up
            // fails without cleaning up), so its logs explain why it never came
            // healthy. Fixing the compose file and re-Upping retries the gate.
            if let composeErr = error as? ComposeError,
               case .serviceUnhealthy(let svc, let dep) = composeErr {
                lastError = OperationError(
                    title: String(localized: "Failed to bring up \"\(record.name)\""),
                    detail: String(localized: "Service \"\(svc)\" depends on \"\(dep)\", which did not become healthy within its health-check window. Open \"\(dep)\" in the Containers tab to view its logs, fix the compose file, then bring the project up again."))
            } else if let composeErr = error as? ComposeError,
                      case .containerNameConflict = composeErr {
                lastError = OperationError(
                    title: String(localized: "Failed to bring up \"\(record.name)\""),
                    detail: composeErr.localizedDescription)
            } else {
                lastError = .from(String(localized: "Failed to bring up \"\(record.name)\""), error: error)
            }
            await refresh()
        }
    }

    /// Open a coordinator task for an Up phase, relabel progress, and return a
    /// handler that only forwards while this phase is current. MainActor-isolated
    /// (mirrors `ContainersModel.beginCreatePhase`) so the @Sendable phase callback
    /// can touch `progress` safely.
    private func beginUpPhase(
        _ label: String, coordinator: ProgressTaskCoordinator,
        progress: OperationProgress, progressHandler: @escaping ProgressUpdateHandler
    ) async -> ProgressUpdateHandler {
        let task = await coordinator.startTask()
        progress.beginPhase(label)
        return ProgressTaskCoordinator.handler(for: task, from: progressHandler)
    }

    // MARK: - Down / remove

    /// Stop and delete a project's containers; optionally its networks/volumes. The
    /// project record is kept so it stays listed and can be re-Upped.
    func down(project name: String, removeVolumes: Bool, removeNetworks: Bool) async {
        lastError = nil
        do {
            try await downThrowing(project: name, removeVolumes: removeVolumes, removeNetworks: removeNetworks)
        } catch {
            guard !error.isCancellation else { return }
            lastError = .from(String(localized: "Failed to bring down \"\(name)\""), error: error)
        }
    }

    /// Throwing core shared with the MCP layer.
    func downThrowing(project name: String, removeVolumes: Bool, removeNetworks: Bool) async throws {
        busyProjects.insert(name)
        defer { busyProjects.remove(name) }
        try await ComposeEngine.down(
            project: name,
            record: store.record(for: name),
            removeVolumes: removeVolumes,
            removeNetworks: removeNetworks)
        await refresh()
    }

    /// Throwing, synchronous-completion Up for the MCP layer. Parses the YAML to
    /// build specs — which also captures the project's declared networks and
    /// volumes so a later `down(removeNetworks:removeVolumes:)` can reclaim them
    /// (a raw record with empty `declaredNetworks/Volumes` would orphan them).
    /// Persists the record, brings the project up, and throws on failure.
    ///
    /// If a project with this name already exists (e.g. imported via the UI with
    /// a base directory and service overrides), those fields are preserved — only
    /// the YAML and declared resources are replaced. This mirrors the UI's
    /// "Up will update it" re-import semantics and prevents silently wiping a
    /// base directory that relative bind mounts resolve against.
    /// Outcome of one service after a capturing Up's wait window.
    struct ServiceUpOutcome: Sendable {
        let service: String
        /// True if the container exited within the wait window (a one-shot/init
        /// service that finished). False means still running at window close.
        let exited: Bool
        /// Exit code, when it exited. Nil while still running.
        let exitCode: Int32?
    }

    @discardableResult
    func upAndWait(record raw: ComposeProjectRecord, waitSeconds: Int = 0) async throws -> [ServiceUpOutcome] {
        let interpolated = try EnvInterpolator.interpolate(
            yaml: raw.yaml, baseDirectory: raw.baseDirectory)
        var file = try ComposeParser.parse(yaml: interpolated.text)
        if let overrides = raw.serviceOverrides, !overrides.isEmpty {
            file = file.applyOverrides(overrides)
        }
        let parse = try file.toSpecs(project: raw.name, baseDirectory: raw.baseDirectory)

        // Rebuild the record with the parsed declarations so teardown is
        // complete, preserving any existing base directory / overrides / import
        // date so a same-name MCP up doesn't orphan relative binds or user edits.
        let existing = store.record(for: raw.name)
        let record = ComposeProjectRecord(
            name: raw.name,
            yaml: raw.yaml,
            baseDirectoryPath: existing?.baseDirectoryPath ?? raw.baseDirectoryPath,
            declaredNetworks: parse.declaredNetworks,
            declaredVolumes: parse.declaredVolumes,
            importedAt: existing?.importedAt ?? raw.importedAt,
            serviceOverrides: existing?.serviceOverrides ?? raw.serviceOverrides)
        try store.save(record)

        busyProjects.insert(record.name)
        defer { busyProjects.remove(record.name) }
        // Fresh Up — drop stale exit codes so a re-up doesn't show a prior run's.
        capturedExitCodes = capturedExitCodes.filter { id, _ in
            !parse.orderedServices.contains { (parse.specs[$0]?.name ?? $0) == id }
        }

        // Attach a wait() to each service the instant it starts — a one-shot can
        // exit before Up returns, and wait() on an already-exited init process
        // hangs, so we must catch it live. Each detached task records its exit
        // code back onto the model; the deadline below reads whatever exited.
        let started = StartedServiceLog()
        let capturing = waitSeconds > 0

        @Sendable func onStarted(_ s: ComposeEngine.StartedService) {
            Task { await started.add(service: s.service, id: s.id) }
            let id = s.id
            let process = s.process
            Task.detached { [weak self] in
                guard let code = try? await process.wait() else { return }
                await self?.recordExitCode(id: id, code: code)
            }
        }

        _ = try await ComposeEngine.up(
            project: record.name, parse: parse,
            onStarted: capturing ? onStarted : nil
        ) { _ in { _ in } }
        lastHostsSignature = ""

        var outcomes: [ServiceUpOutcome] = []
        if waitSeconds > 0 {
            try? await Task.sleep(for: .seconds(waitSeconds))
            let services = await started.all()
            outcomes = services.map { entry in
                if let code = capturedExitCodes[entry.id] {
                    return ServiceUpOutcome(service: entry.service, exited: true, exitCode: code)
                }
                return ServiceUpOutcome(service: entry.service, exited: false, exitCode: nil)
            }
        }
        await refresh()
        return outcomes
    }

    /// Record a container's exit code, reported by a detached wait task started
    /// during a capturing Up. MainActor-isolated so the concurrent waits mutate
    /// `capturedExitCodes` without a data race.
    private func recordExitCode(id: String, code: Int32) {
        capturedExitCodes[id] = code
    }

    /// Records which services started during a capturing Up, populated from the
    /// `@Sendable onStarted` callback (which can fire off the main actor). An
    /// actor so those concurrent appends don't race.
    private actor StartedServiceLog {
        struct Entry { let service: String; let id: String }
        private var entries: [Entry] = []
        func add(service: String, id: String) { entries.append(Entry(service: service, id: id)) }
        func all() -> [Entry] { entries }
    }

    /// Start all stopped containers in a project without creating new ones.
    func start(project name: String) async {
        lastError = nil
        busyProjects.insert(name)
        defer { busyProjects.remove(name) }
        do {
            try await ComposeEngine.start(project: name)
            await refresh()
        } catch {
            guard !error.isCancellation else { return }
            lastError = .from(String(localized: "Failed to start \"\(name)\""), error: error)
        }
    }

    /// Stop all running containers in a project without deleting them.
    func stop(project name: String) async {
        lastError = nil
        busyProjects.insert(name)
        defer { busyProjects.remove(name) }
        do {
            try await ComposeEngine.stop(project: name)
            await refresh()
        } catch {
            guard !error.isCancellation else { return }
            lastError = .from(String(localized: "Failed to stop \"\(name)\""), error: error)
        }
    }

    /// Delete the project's containers AND its persisted record/files. Always
    /// clears resources so nothing is orphaned.
    func remove(project name: String) async {
        await down(project: name, removeVolumes: true, removeNetworks: true)
        store.remove(project: name)
        await refresh()
    }
}
