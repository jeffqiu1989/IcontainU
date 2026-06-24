import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Observation
import TerminalProgress

@Observable
@MainActor
final class ContainersModel {
    private(set) var containers: [ContainerSnapshot] = []
    /// Transient list-fetch failure: managed entirely by `refresh`.
    private(set) var pollError: String?
    /// Failure (or notice) from an explicit action: never cleared by polling.
    private(set) var lastError: OperationError?
    private(set) var creating: OperationProgress?
    private(set) var busyItemIDs: Set<String> = []
    private var createTask: Task<Void, Never>?

    func clearError() { lastError = nil }

    /// Resources offered in the create form's volume / network pickers.
    private(set) var availableVolumes: [VolumeConfiguration] = []
    private(set) var availableNetworks: [NetworkResource] = []
    /// Local image references (denormalized, e.g. `nginx:latest`) offered as
    /// autocomplete suggestions and used to decide whether the create form's image
    /// is already present (Analyze) or still needs fetching (Pull).
    private(set) var availableImages: [String] = []
    /// Progress for an image pull triggered from the create form (Pull button).
    private(set) var pulling: OperationProgress?
    private var pullTask: Task<Bool, Never>?
    private(set) var pullForCreateTask: Task<Bool, Never>?

    // Build a fresh client (and XPC connection) per use. The Apple clients cache
    // their XPC connection for the object's lifetime; a long-lived cached
    // connection goes invalid when the apiserver restarts (e.g. the first
    // `container system start`), which then breaks every container call until the
    // app is relaunched. `ClientImage` already connects per call — mirror that so a
    // restarted apiserver is transparently reconnected on the next call.
    private var client: ContainerClient { ContainerClient() }
    private var networkClient: NetworkClient { NetworkClient() }

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        do {
            // No status filter → include stopped containers (otherwise a container
            // vanishes from the list the moment it stops). Exclude machines, which
            // are containers under the hood but managed in their own tab.
            let filters = ContainerListFilters.all.withoutMachines()
            // Sort by id so card order is stable across polls (the server's list
            // order is not guaranteed, which would otherwise reshuffle cards every
            // refresh). Richer status/started-time ordering is a separate feature.
            containers = try await client.list(filters: filters).sorted { $0.id < $1.id }
            pollError = nil
        } catch {
            pollError = error.localizedDescription
        }
    }

    /// Detached start: bootstrap with no stdio attached, then start the process.
    func start(_ container: ContainerSnapshot) async {
        lastError = nil
        busyItemIDs.insert(container.id)
        defer { busyItemIDs.remove(container.id) }
        do {
            let process = try await client.bootstrap(id: container.id, stdio: [nil, nil, nil])
            try await process.start()
            await refresh()
        } catch {
            lastError = OperationError(title: "Failed to start container", detail: error.localizedDescription)
        }
    }

    func stop(_ container: ContainerSnapshot) async {
        lastError = nil
        busyItemIDs.insert(container.id)
        defer { busyItemIDs.remove(container.id) }
        do {
            try await client.stop(id: container.id)
            await refresh()
        } catch {
            lastError = OperationError(title: "Failed to stop container", detail: error.localizedDescription)
        }
    }

    func delete(_ container: ContainerSnapshot, force: Bool) async {
        lastError = nil
        busyItemIDs.insert(container.id)
        defer { busyItemIDs.remove(container.id) }
        do {
            try await client.delete(id: container.id, force: force)
            await refresh()
        } catch {
            lastError = OperationError(title: "Failed to delete container", detail: error.localizedDescription)
        }
    }

    /// Open an interactive shell in the container via the system Terminal.
    func openShell(_ container: ContainerSnapshot) {
        lastError = nil
        do {
            try TerminalLauncher.execInContainer(id: container.id)
        } catch {
            lastError = OperationError(title: "Failed to open Terminal", detail: error.localizedDescription)
        }
    }

    /// Analyze an image to pre-fill the create form. Best effort: returns an empty
    /// metadata on failure and surfaces the error so the user knows why.
    func analyze(image: String) async -> ImageMetadata {
        let trimmed = image.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
            let platform = try? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
        else { return ImageMetadata() }
        do {
            let config = try await SystemConfig.load()
            let img = try await ClientImage.get(reference: trimmed, containerSystemConfig: config)
            let metadata = try await ImageInspector.analyze(image: img, platform: platform)
            return metadata
        } catch {
            lastError = .from("Image analysis failed", error: error)
            return ImageMetadata()
        }
    }

    /// Load the volumes, networks and local images offered in the create form's
    /// pickers / autocomplete. Best effort: a failure here just leaves the inputs
    /// with built-in options.
    func loadCreateResources() async {
        async let volumes = try? ClientVolume.list()
        async let networks = try? networkClient.list()
        availableVolumes = (await volumes ?? []).sorted { $0.name < $1.name }
        availableNetworks = await networks ?? []
        await refreshAvailableImages()
    }

    /// Refresh the local image suggestion list, denormalized for display and
    /// deduplicated. Best effort.
    private func refreshAvailableImages() async {
        guard let raw = try? await ClientImage.list() else { return }
        var seen = Set<String>()
        var refs: [String] = []
        for image in raw {
            let parsed = ParsedImageReference(image.reference)
            let display = parsed.tag.map { "\(parsed.repository):\($0)" } ?? parsed.repository
            guard seen.insert(display).inserted else { continue }
            refs.append(display)
        }
        availableImages = refs.sorted()
    }

    /// True when `reference` already matches a local image — i.e. the create form
    /// can Analyze it directly instead of pulling. An untagged input matches any
    /// tag of the same repository (mirroring the implicit `:latest`).
    func isImageLocal(_ reference: String) -> Bool {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let parsed = ParsedImageReference(trimmed)
        for local in availableImages {
            if local == trimmed { return true }
            let localParsed = ParsedImageReference(local)
            if localParsed.repository == parsed.repository {
                // Untagged input → repository match is enough; otherwise tags must match.
                if parsed.tag == nil || parsed.tag == localParsed.tag { return true }
            }
        }
        return false
    }

    /// Pull (and unpack) an image for the create form, reporting progress on
    /// `pulling`. Returns true on success so the caller can then analyze it.
    func cancelPull() {
        pullTask?.cancel()
        pulling = nil
    }

    func startPullForCreate(reference: String) {
        cancelPull()
        let task = Task<Bool, Never> { [weak self] in
            await self?._pullForCreate(reference: reference) ?? false
        }
        pullTask = task
        pullForCreateTask = task
    }

    private func _pullForCreate(reference: String) async -> Bool {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        lastError = nil

        let platform = try? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
        let viaMirror = RegistryMirrorStore.shared.rewrite(trimmed) != trimmed
        let progress = OperationProgress()
        progress.beginPhase(viaMirror ? "Pulling \(trimmed) via mirror…" : "Pulling \(trimmed)…")
        pulling = progress
        defer { pulling = nil }

        let coordinator = ProgressTaskCoordinator()
        defer { Task { await coordinator.finish() } }
        do {
            let config = try await SystemConfig.load()
            let fetchTask = await coordinator.startTask()
            let image = try await MirrorPull.pull(
                originalReference: trimmed,
                platform: platform,
                config: config,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: pullProgressHandler))

            let unpackTask = await coordinator.startTask()
            pulling?.beginPhase("Unpacking…")
            try await image.unpack(
                platform: platform,
                progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: pullProgressHandler))
            await refreshAvailableImages()
            return true
        } catch is CancellationError {
            // User cancelled — not an error. defer sets pulling = nil.
            return false
        } catch {
            lastError = .from("Failed to pull image", error: error)
            return false
        }
    }

    private var pullProgressHandler: ProgressUpdateHandler {
        { [weak self] events in
            await self?.applyPullProgress(events)
        }
    }

    private func applyPullProgress(_ events: [ProgressUpdateEvent]) {
        pulling?.apply(events)
    }

    /// Create + start a container. Image fetch and container prepare are run as
    /// two coordinated phases (see `pullImage` for the rationale): late events
    /// from the finished fetch phase are dropped instead of disturbing the
    /// prepare bar, and each phase is labeled explicitly.
    func cancelCreate() {
        createTask?.cancel()
        creating = nil
    }

    func startCreate(spec: ContainerCreateSpec) {
        cancelCreate()
        createTask = Task { [weak self] in
            await self?._create(spec: spec)
        }
    }

    private func _create(spec: ContainerCreateSpec) async {
        lastError = nil
        creating = OperationProgress()
        defer { creating = nil }

        let coordinator = ProgressTaskCoordinator()
        do {
            let id = try await ContainerCreateEngine.create(spec: spec) { [weak self] label in
                await self?.beginCreatePhase(label, coordinator: coordinator) ?? { _ in }
            }
            await coordinator.finish()
            await refresh()
            await reportIfStopped(id: id)
        } catch is CancellationError {
            await coordinator.finish()
        } catch {
            await coordinator.finish()
            lastError = .from("Failed to create container", error: error)
        }
    }

    /// Open a new coordinator task for a create phase, relabel the progress, and
    /// return a handler that only forwards while this phase is current.
    private func beginCreatePhase(
        _ label: String, coordinator: ProgressTaskCoordinator
    ) async -> ProgressUpdateHandler {
        let task = await coordinator.startTask()
        creating?.beginPhase(label)
        return ProgressTaskCoordinator.handler(for: task, from: progressHandler)
    }

    /// A freshly created container may already be stopped — and that is not
    /// necessarily an error. A shell base image exits immediately with no command,
    /// a one-shot job exits when its work is done, and a misconfigured run fails.
    /// Detached start has no exit code to tell these apart, so stay neutral and
    /// point the user at the logs (full detail is also in the `swift run` console).
    private func reportIfStopped(id: String) async {
        try? await Task.sleep(for: .seconds(2))
        await refresh()
        guard let container = containers.first(where: { $0.id == id }) else { return }
        if container.status == .stopped {
            lastError = OperationError(
                title: "Container already stopped",
                detail: "Container \"\(id)\" has already stopped. "
                    + "If that wasn't expected, open it and check the Logs tab.")
        }
    }

    private var progressHandler: ProgressUpdateHandler {
        { [weak self] events in
            await self?.applyProgress(events)
        }
    }

    private func applyProgress(_ events: [ProgressUpdateEvent]) {
        creating?.apply(events)
    }
}
