import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import ContainerizationOCI
import Foundation
import MachineAPIClient
import Observation
import TerminalProgress

@Observable
@MainActor
final class MachinesModel {
    private(set) var machines: [MachineSnapshot] = []
    private(set) var defaultID: String?
    /// Transient list-fetch failure: managed entirely by `refresh`.
    private(set) var pollError: String?
    /// Failure of an explicit action: never cleared by polling.
    private(set) var lastError: OperationError?
    private(set) var creating: OperationProgress?
    private(set) var busyItemIDs: Set<String> = []
    private var createTask: Task<Void, Never>?
    /// Generation token guarding `creating` against superseded tasks. A cancel only
    /// aborts the client-side await — the image pull's XPC send has no timeout and
    /// its reply continuation ignores cancellation, so a cancelled task keeps
    /// running its server-side pull to completion. Incrementing this on every
    /// cancel/start invalidates in-flight tasks: their captured generation is then
    /// stale, so their `defer` refuses to nil a newer task's `creating` slot. See
    /// the plan at `.claude/plans/pull-machine-wiggly-squirrel.md`.
    private var createGeneration = 0

    func clearError() { lastError = nil }

    // Fresh client per use so a restarted apiserver is reconnected automatically;
    // a cached XPC connection goes invalid across apiserver restarts. See
    // ContainersModel for the full rationale.
    private var client: MachineClient { MachineClient() }

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        do {
            async let list = client.list()
            async let def = client.getDefault()
            // Stable newest-first sort. The server iterates a Dictionary and
            // returns an unspecified order that would reshuffle cards every poll.
            // Sort by `createdDate` descending (newest on top) with id ascending as
            // the tiebreaker for a full, jitter-free order. `createdDate` is set
            // once at create and never updated, so start/stop never moves a card —
            // only a newer machine landing above it can. Legacy bundles without a
            // `createdDate` sort last (`.distantPast`).
            machines = try await list.sorted { a, b in
                let ta = a.createdDate ?? .distantPast
                let tb = b.createdDate ?? .distantPast
                return ta == tb ? a.id < b.id : ta > tb
            }
            defaultID = try await def
            pollError = nil
        } catch {
            pollError = error.localizedDescription
        }
    }

    func boot(_ machine: MachineSnapshot) async {
        lastError = nil
        do {
            try await bootThrowing(machine)
        } catch {
            guard !error.isCancellation else { return }
            lastError = OperationError(title: "Failed to start machine", detail: error.localizedDescription)
        }
    }

    /// Throwing core shared with the MCP layer.
    func bootThrowing(_ machine: MachineSnapshot) async throws {
        busyItemIDs.insert(machine.id)
        defer { busyItemIDs.remove(machine.id) }
        _ = try await client.boot(id: machine.id)
        await refresh()
    }

    func stop(_ machine: MachineSnapshot) async {
        lastError = nil
        do {
            try await stopThrowing(machine)
        } catch {
            guard !error.isCancellation else { return }
            lastError = OperationError(title: "Failed to stop machine", detail: error.localizedDescription)
        }
    }

    func stopThrowing(_ machine: MachineSnapshot) async throws {
        busyItemIDs.insert(machine.id)
        defer { busyItemIDs.remove(machine.id) }
        try await client.stop(id: machine.id)
        await refresh()
    }

    /// Open an interactive shell in the machine via the system Terminal.
    /// `machine run` boots the machine first if it is stopped.
    func openShell(_ machine: MachineSnapshot) {
        lastError = nil
        do {
            try TerminalLauncher.runInMachine(id: machine.id)
        } catch {
            lastError = OperationError(title: "Failed to open Terminal", detail: error.localizedDescription)
        }
    }

    func delete(_ machine: MachineSnapshot) async {
        lastError = nil
        do {
            try await deleteThrowing(machine)
        } catch {
            guard !error.isCancellation else { return }
            lastError = OperationError(title: "Failed to delete machine", detail: error.localizedDescription)
        }
    }

    func deleteThrowing(_ machine: MachineSnapshot) async throws {
        busyItemIDs.insert(machine.id)
        defer { busyItemIDs.remove(machine.id) }
        try await client.delete(id: machine.id)
        await refresh()
    }

    /// Create a machine from an image. Honors registry mirrors (with retag back to
    /// the canonical reference). Assembles the config inline rather than via the
    /// CLI's `machineConfigFromFlags`, whose ArgumentParser `Flags` types crash
    /// when constructed outside of command-line parsing.
    func cancelCreate() {
        createGeneration &+= 1
        createTask?.cancel()
        creating = nil
    }

    func startCreate(
        image: String,
        name: String?,
        cpus: Int?,
        memory: String?,
        homeMount: String?,
        setAsDefault: Bool,
        noBoot: Bool
    ) {
        cancelCreate()
        let generation = createGeneration
        createTask = Task { [weak self] in
            await self?._create(
                image: image, name: name, cpus: cpus, memory: memory,
                homeMount: homeMount, setAsDefault: setAsDefault, noBoot: noBoot,
                generation: generation)
        }
    }

    private func _create(
        image: String,
        name: String?,
        cpus: Int?,
        memory: String?,
        homeMount: String?,
        setAsDefault: Bool,
        noBoot: Bool,
        generation: Int
    ) async {
        let trimmedImage = image.trimmingCharacters(in: .whitespaces)
        guard !trimmedImage.isEmpty else { return }

        // Name is required. The view enforces this (CreateMachineSheet.canCreate),
        // but the model enforces it too so a non-view caller (a future automation
        // hook or test) can't silently fall through to `machineID`'s image-derived
        // id — which would contradict the "name required" decision.
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            lastError = OperationError(
                title: "Name required",
                detail: "A machine name is required.")
            return
        }

        lastError = nil
        let progress = OperationProgress()
        progress.beginPhase("Fetching image…")
        // Only the current generation owns `creating`: a superseded task (cancelled
        // but still running its server-side pull) must not set or clear it. Return
        // entirely — a superseded task has nothing useful to do.
        guard createGeneration == generation else { return }
        creating = progress
        defer { if createGeneration == generation { creating = nil } }

        // Apply events to OUR `progress`, not `self.creating`, so a stale task's
        // late events land on an orphan nobody observes instead of disturbing the
        // active bar. (Same actor hop as the old `self.applyProgress`.)
        let progressHandler: ProgressUpdateHandler = { [weak progress] events in
            await progress?.apply(events)
        }

        let coordinator = ProgressTaskCoordinator()
        defer { Task { await coordinator.finish() } }

        do {
            let config = try await SystemConfig.load()

            guard let platform = try? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)") else {
                throw ContainerizationError(.invalidArgument, message: "could not resolve host platform")
            }

            // Boot config: start from system defaults, override only provided fields.
            let bootConfig = try config.machine.with(
                [
                    "cpus": cpus.map { "\($0)" },
                    "memory": memory,
                    "home-mount": homeMount,
                ].compactMapValues { $0 }
            )

            // Fetch the image local-first (Docker `run` semantics, matching
            // container creation): use the cached image when present, fetching
            // through a mirror only when it is missing. This lets a machine be
            // created offline when its image is already local — `pull` would
            // instead force a registry round-trip that fails with no network.
            let fetchTask = await coordinator.startTask()
            let img = try await MirrorPull.fetch(
                originalReference: trimmedImage,
                platform: platform,
                config: config,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progressHandler))

            // The image fetch's underlying XPC `send` carries NO response timeout,
            // and its reply continuation does not observe cancellation — so a
            // Cancel pressed mid-pull does NOT abort the underlying pull; it returns
            // normally once the server-side pull finishes. We must therefore check
            // cancellation ourselves at every phase boundary, before any
            // non-idempotent step, so a cancel during pull/unpack stops us *before*
            // `create` rather than silently falling through to it. `pull`/`unpack`
            // ran server-side regardless (harmless — both idempotent); we simply
            // decline to proceed. `checkCancellation` throws `CancellationError`,
            // handled as a non-error by the outer catch.
            try Task.checkCancellation()

            // Unpack into a create snapshot before use.
            let unpackTask = await coordinator.startTask()
            progress.beginPhase("Unpacking image…")
            _ = try await img.getCreateSnapshot(
                platform: platform,
                progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progressHandler))

            try Task.checkCancellation()

            // Determine the machine id (auto-derive from the canonical image when blank).
            let id = try machineID(name: name, image: img.reference)
            try Utility.validEntityName(id)

            let userSetup = UserSetup(username: NSUserName(), uid: getuid(), gid: getgid())
            let machineConfig = try MachineConfiguration(
                id: id,
                image: img.description,
                platform: platform,
                userSetup: userSetup)

            // --- Create phase: a duplicate name surfaces as an error, not silent reuse. ---
            //
            // `create` is a single XPC call that runs to completion under a lock and
            // does NOT respond to the client's cancellation, so a cancelled create can
            // still finish server-side — leaving a machine under this id. A repeat with
            // the same name (deliberate or accidental) would then collide. We surface
            // that collision as an explicit error rather than silently reusing the
            // existing machine: the user sees "already exists" and decides whether to
            // boot it from the list or delete it first. (Silent reuse previously made a
            // duplicate look like a no-op — the progress bar said "Creating machine…"
            // while nothing was created, which reads as a failure.)
            try Task.checkCancellation()

            progress.beginPhase("Creating machine…")
            // The "already exists" message is shared by the pre-check and the
            // server-side `.exists` race catch — one local so the two can't drift.
            let alreadyExistsError = OperationError(
                title: "Machine already exists",
                detail: "A machine named \"\(id)\" already exists. Boot it from the list, or delete it first.")
            let alreadyExists = machines.contains { $0.id == id }
            if alreadyExists {
                lastError = alreadyExistsError
                return
            }
            do {
                try await client.create(
                    configuration: machineConfig, resources: nil, bootConfig: bootConfig)
            } catch let error as ContainerizationError where error.code == .exists {
                // Race: created server-side between our check and this call (the cached
                // list lagged a completion by up to the 2s poll). Treat as a duplicate,
                // not silent reuse — surface it so the user knows. A superseded task
                // resumed after its `client.create` XPC ignored cancellation must not
                // clobber the active task's error — drop it silently.
                guard createGeneration == generation else { return }
                lastError = alreadyExistsError
                return
            } catch {
                // A superseded task resumed after its XPC call ignored cancellation:
                // drop its error so it doesn't clobber the active task's.
                guard createGeneration == generation else { return }
                guard !error.isCancellation else { return }
                lastError = .from("Failed to create machine", error: error)
                return
            }

            // Boot tail, only for a genuinely fresh create. `boot` is idempotent.
            // Boot BEFORE setAsDefault: a cancelled/failed boot must not leave an
            // unbooted machine as the persisted default, so only mark it default once
            // it's actually running. `refresh` runs even on boot failure so the
            // (created-but-stopped) machine shows up in the list regardless.
            do {
                if !noBoot {
                    progress.beginPhase("Starting machine…")
                    _ = try await client.boot(id: id)
                }
                if setAsDefault {
                    try await client.setDefault(id: id)
                }
            } catch {
                // A superseded task resumed after its XPC call ignored cancellation:
                // drop its error so it doesn't clobber the active task's.
                guard createGeneration == generation else { return }
                guard !error.isCancellation else { return }
                lastError = .from("Failed to start machine", error: error)
            }
            await refresh()
        } catch {
            // A cancellation during fetch/unpack — raw, or wrapped by
            // `MirrorPull`/`ClientImage` into a `ContainerizationError(cause:
            // CancellationError)` — is the user aborting, not a failure; `defer`
            // clears `creating`. See `Error.isCancellation`. Nothing here has
            // side effects yet (pull/unpack are idempotent), so a retry is clean.
            // A superseded task resumed after an XPC call ignored cancellation must
            // not clobber the active task's error — drop it.
            guard createGeneration == generation else { return }
            guard !error.isCancellation else { return }
            lastError = .from("Failed to create machine", error: error)
        }
    }

    /// Mirror the CLI's id derivation: explicit name, else `<imageName>-<tag>`.
    private func machineID(name: String?, image: String) throws -> String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name.trimmingCharacters(in: .whitespaces)
        }
        let reference = try Reference.parse(image)
        reference.normalize()
        let imageName = reference.name.components(separatedBy: "/").last ?? reference.name
        let suffix = reference.tag ?? reference.digest ?? "latest"
        return "\(imageName)-\(suffix)"
    }

}
