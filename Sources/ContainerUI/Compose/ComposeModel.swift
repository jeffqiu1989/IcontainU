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
    var totalCount: Int { services.count }
    /// A project with no running containers — fully down (or never upped).
    var isDown: Bool { runningCount == 0 }
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

    /// Projects with at least one container we couldn't write `/etc/hosts` into
    /// (e.g. an image without `/bin/sh`), so service discovery may be degraded.
    /// Surfaced as a small warning badge on the project card.
    private(set) var hostsDegraded: Set<String> = []

    private let store = ComposeProjectStore.shared

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
                    ComposeServiceStatus(service: $0, status: live[$0]?.status, containerID: live[$0]?.id)
                }
                views.append(ComposeProjectView(name: record.name, services: services, isStored: true))
            }

            // Projects seen only in running containers (e.g. started via CLI).
            for (project, live) in byProject where !seen.contains(project) {
                let services = live.keys.sorted().map {
                    ComposeServiceStatus(service: $0, status: live[$0]?.status, containerID: live[$0]?.id)
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
        let file = try ComposeParser.parse(yaml: yaml)
        return try file.toSpecs(project: projectName, baseDirectory: baseDirectory)
    }

    /// Parse + lower returning both the file (for override diffing) and the result.
    func analyzeWithFile(yaml: String, baseDirectory: URL?, projectName: String) throws -> (ComposeFile, ComposeParseResult) {
        let file = try ComposeParser.parse(yaml: yaml)
        let result = try file.toSpecs(project: projectName, baseDirectory: baseDirectory)
        return (file, result)
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
                var file = try ComposeParser.parse(yaml: record.yaml)
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

        let progress = OperationProgress(phaseLabel: "Starting \(record.name)…")
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
                    title: "Failed to bring up \"\(record.name)\"",
                    detail: "Service \"\(svc)\" depends on \"\(dep)\", which did not "
                        + "become healthy within its health-check window. Open \"\(dep)\" "
                        + "in the Containers tab to view its logs, fix the compose file, "
                        + "then bring the project up again.")
            } else if let composeErr = error as? ComposeError,
                      case .containerNameConflict = composeErr {
                lastError = OperationError(
                    title: "Failed to bring up \"\(record.name)\"",
                    detail: composeErr.localizedDescription)
            } else {
                lastError = .from("Failed to bring up \"\(record.name)\"", error: error)
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
        busyProjects.insert(name)
        defer { busyProjects.remove(name) }
        do {
            try await ComposeEngine.down(
                project: name,
                record: store.record(for: name),
                removeVolumes: removeVolumes,
                removeNetworks: removeNetworks)
            await refresh()
        } catch {
            guard !error.isCancellation else { return }
            lastError = .from("Failed to bring down \"\(name)\"", error: error)
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
