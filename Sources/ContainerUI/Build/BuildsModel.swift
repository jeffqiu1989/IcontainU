import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Observation
import TerminalProgress

/// One build config merged with its live state — what a `BuildConfigCard` renders.
struct BuildConfigView: Identifiable {
    var record: BuildConfigRecord
    /// True while this config's build is the active one.
    var isBuilding: Bool

    var id: String { record.name }
}

/// The in-flight build. A single slot: builds are strictly serial because they
/// all share one builder container (one BuildKit daemon, one vsock).
@MainActor
struct ActiveBuild {
    let configName: String
    /// Whether this build runs with `--no-cache`. Drives the builder lifecycle
    /// on completion and cancel: a no-cache build deletes the builder (reclaims
    /// the disk its layer cache would otherwise grow into), a cached build stops
    /// it (keeps the cache for fast rebuilds).
    let noCache: Bool
    let progress: OperationProgress
    let log: LogBuffer
    let startedAt: Date
}

/// Unified build orchestrator: owns the persisted build configs (the cards), the
/// single active build slot, the builder container's lifecycle (including idle
/// auto-stop), and runs every image build — both standalone config cards and
/// compose `build:` services route through here, so all build state and logs
/// live in one place (the Build section).
///
/// Cancellation mirrors `ImagesModel`'s pull machinery: a generation token guards
/// the active slot against superseded tasks, because the server-side BuildKit
/// build cannot actually be aborted — cancelling only stops us from tracking it.
@Observable
@MainActor
final class BuildsModel {
    /// Build configs (persisted cards) merged with live state.
    private(set) var configs: [BuildConfigView] = []

    /// The in-flight build, if any. Single slot — serial builds.
    private(set) var activeBuild: ActiveBuild?

    /// Failure of the last explicit action. Never cleared by polling.
    private(set) var lastError: OperationError?

    private let store = BuildConfigStore.shared

    private var buildTask: Task<Void, Never>?
    /// Generation token — bumped on every cancel/start so a superseded task can
    /// detect it no longer owns `activeBuild`.
    private var buildGeneration = 0

    var isBuilding: Bool { activeBuild != nil }

    func clearError() { lastError = nil }

    // MARK: - Polling / refresh

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh() async {
        refreshConfigs()
    }

    private func refreshConfigs() {
        let activeName = activeBuild?.configName
        configs = store.records.map { record in
            BuildConfigView(record: record, isBuilding: record.name == activeName)
        }
    }

    // MARK: - Config CRUD

    /// Persist a config (create or update) without building.
    func saveConfig(_ record: BuildConfigRecord) {
        do {
            try store.save(record)
            refreshConfigs()
        } catch {
            lastError = .from("Failed to save build config", error: error)
        }
    }

    /// Remove a config card. Built images are left in the image store.
    func removeConfig(name: String) {
        if activeBuild?.configName == name { cancelBuild() }
        store.remove(config: name)
        refreshConfigs()
    }

    /// Remove every compose-derived config belonging to `project` — called when
    /// the compose project itself is removed. Built images are kept (a re-import
    /// + up can reuse them).
    func removeComposeConfigs(project: String) {
        for record in store.records(forComposeProject: project) {
            if activeBuild?.configName == record.name { cancelBuild() }
            store.remove(config: record.name)
        }
        refreshConfigs()
    }

    /// The log buffer to show for a config: the live stream while it's building,
    /// else a static snapshot of the persisted last-build tail.
    func logBuffer(for name: String) -> LogBuffer {
        if let active = activeBuild, active.configName == name {
            return active.log
        }
        let snapshot = LogBuffer()
        snapshot.load(snapshot: store.record(for: name)?.lastBuild?.logTail ?? [])
        return snapshot
    }

    // MARK: - Build (standalone cards)

    /// Cancel the active build AND stop/delete the builder right away - the
    /// server-side BuildKit build can't be aborted any other way than killing
    /// the container, which is also what frees the RAM the user expects gone on
    /// cancel. A no-cache build deletes the builder (nothing worth caching); a
    /// cached build stops it (preserves layers for the next rebuild). No-op on
    /// the builder when there was no active build (e.g. `startBuild` clearing a
    /// nil slot, or `removeConfig` on a non-building config).
    func cancelBuild() {
        let wasNoCache = activeBuild?.noCache ?? false
        let hadActive = activeBuild != nil
        buildGeneration &+= 1
        buildTask?.cancel()
        activeBuild?.log.close()
        activeBuild = nil
        refreshConfigs()
        guard hadActive else { return }
        Task { [weak self] in
            // Via stopBuilder/deleteBuilder so failures surface (and they refresh).
            if wasNoCache { await self?.deleteBuilder() }
            else { await self?.stopBuilder() }
        }
    }

    /// Build a config card. Serial: rejects when another build is in flight
    /// (the view disables Build buttons, this is the backstop).
    func startBuild(record: BuildConfigRecord) {
        guard activeBuild == nil else {
            lastError = OperationError(
                title: String(localized: "A build is already running"),
                detail: String(localized: "Wait for \"\(activeBuild?.configName ?? "")\" to finish, or cancel it first."))
            return
        }
        cancelBuild()
        let generation = buildGeneration
        buildTask = Task { [weak self] in
            await self?._runBuild(record: record, generation: generation)
        }
    }

    // MARK: - Build (compose services)

    /// Run a compose service's build through the shared slot, awaiting the
    /// result. Called from `ComposeEngine.up` (via ComposeModel) so compose
    /// builds surface in the Build section like any other build.
    ///
    /// Upserts a compose-derived config card first, so the build has a card to
    /// stream its log into. Throws on failure (the compose Up aborts); the
    /// failure outcome (message + log tail) is persisted on the card either way.
    func runBuildForCompose(spec: BuildSpec, project: String, service: String) async throws {
        // One card per compose service: "<project>-<service>".
        let name = "\(project)-\(service)"
        var record = store.record(for: name)
            ?? BuildConfigRecord(
                name: name,
                contextDirPath: spec.contextDir.path,
                dockerfilePath: spec.dockerfilePath.path,
                tags: spec.tags,
                platforms: spec.platforms.map(\.description),
                noCache: spec.noCache,
                buildArgs: spec.buildArgs,
                target: spec.target,
                labels: spec.labels,
                pull: spec.pull,
                source: .compose(project: project, service: service),
                createdAt: Date(),
                lastBuild: nil)
        // Keep the card in sync with the compose file (context/target may change).
        record.contextDirPath = spec.contextDir.path
        record.dockerfilePath = spec.dockerfilePath.path
        record.tags = spec.tags
        record.target = spec.target
        try? store.save(record)

        // Wait for any in-flight build to finish (compose builds queue behind the
        // active one rather than failing the whole Up).
        while activeBuild != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(300))
        }

        buildGeneration &+= 1
        let generation = buildGeneration
        try await _runBuildThrowing(record: record, spec: spec, generation: generation)
    }

    // MARK: - Core build flow

    private func _runBuild(record: BuildConfigRecord, generation: Int) async {
        lastError = nil
        do {
            let spec = makeSpec(from: record)
            try await _runBuildThrowing(record: record, spec: spec, generation: generation)
        } catch is CancellationError {
            // User cancelled — not an error; cancelBuild already cleaned up.
        } catch {
            guard buildGeneration == generation else { return }
            guard !error.isCancellation else { return }
            lastError = OperationError(
                title: "Failed to build image", detail: error.buildFailureDetail)
        }
    }

    /// Shared core: sets up the active slot, runs BuildEngine, snapshots the
    /// outcome onto the record, and rethrows failures (compose needs the throw).
    private func _runBuildThrowing(
        record: BuildConfigRecord, spec: BuildSpec, generation: Int
    ) async throws {
        let progress = OperationProgress(phaseLabel: String(localized: "Preparing builder…"))
        let log = LogBuffer()
        let started = Date()

        guard buildGeneration == generation else { return }
        activeBuild = ActiveBuild(
            configName: record.name, noCache: spec.noCache,
            progress: progress, log: log, startedAt: started)
        refreshConfigs()
        defer {
            if buildGeneration == generation {
                log.close()
                activeBuild = nil
                refreshConfigs()
                // "用完就停": stop/delete the builder the moment the build is done -
                // no idle window. noCache deletes (reclaims disk, no cache worth
                // keeping); a cached build stops (RAM freed, layer cache kept on
                // disk for the next rebuild). Routed through stopBuilder/
                // deleteBuilder so a failure surfaces instead of being swallowed.
                Task { [weak self] in
                    if spec.noCache { await self?.deleteBuilder() }
                    else { await self?.stopBuilder() }
                }
            }
        }

        let beginPhase: @Sendable (String) async -> ProgressUpdateHandler = { [weak progress] label in
            await MainActor.run { progress?.beginPhase(label) }
            return { [weak progress] events in
                await progress?.apply(events)
            }
        }

        do {
            try await BuildEngine.build(
                spec: spec,
                beginPhase: beginPhase,
                onLog: { line in log.append(line) })
            try Task.checkCancellation()
            snapshotOutcome(
                record: record, started: started, generation: generation,
                status: .succeeded, message: "", log: log)
        } catch {
            if buildGeneration == generation, !(error is CancellationError), !error.isCancellation {
                snapshotOutcome(
                    record: record, started: started, generation: generation,
                    status: .failed, message: error.localizedDescription, log: log)
            }
            throw error
        }
    }

    /// Persist the finished build's outcome (status + log tail) onto the record.
    private func snapshotOutcome(
        record: BuildConfigRecord, started: Date, generation: Int,
        status: BuildOutcome.Status, message: String, log: LogBuffer
    ) {
        guard buildGeneration == generation else { return }
        log.close()
        var updated = store.record(for: record.name) ?? record
        updated.lastBuild = BuildOutcome(
            status: status,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            message: message,
            logTail: log.tail(BuildConfigStore.logTailLimit))
        try? store.save(updated)
        refreshConfigs()
    }

    private func makeSpec(from record: BuildConfigRecord) -> BuildSpec {
        BuildSpec(
            contextDir: record.contextDir,
            dockerfilePath: record.dockerfile,
            tags: record.tags,
            platforms: record.platforms.compactMap { try? Platform(from: $0) },
            noCache: record.noCache,
            buildArgs: record.buildArgs,
            target: record.target,
            labels: record.labels,
            pull: record.pull)
    }

    // MARK: - Builder lifecycle

    func stopBuilder() async {
        do {
            try await BuilderLifecycle.stop()
            await refresh()
        } catch {
            lastError = .from("Failed to stop builder", error: error)
        }
    }

    /// Delete the builder container entirely — discards the BuildKit layer cache.
    /// Called by the build lifecycle (no-cache builds / cancel); not surfaced in
    /// the Build UI - check/remove the builder from the Containers page.
    func deleteBuilder() async {
        do {
            try await BuilderLifecycle.delete()
            await refresh()
        } catch {
            lastError = .from("Failed to delete builder", error: error)
        }
    }
}
