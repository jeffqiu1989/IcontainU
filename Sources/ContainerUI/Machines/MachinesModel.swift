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
            machines = try await list
            defaultID = try await def
            pollError = nil
        } catch {
            pollError = error.localizedDescription
        }
    }

    func boot(_ machine: MachineSnapshot) async {
        lastError = nil
        do {
            _ = try await client.boot(id: machine.id)
            await refresh()
        } catch {
            lastError = OperationError(title: "Failed to start machine", detail: error.localizedDescription)
        }
    }

    func stop(_ machine: MachineSnapshot) async {
        lastError = nil
        do {
            try await client.stop(id: machine.id)
            await refresh()
        } catch {
            lastError = OperationError(title: "Failed to stop machine", detail: error.localizedDescription)
        }
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
            try await client.delete(id: machine.id)
            await refresh()
        } catch {
            lastError = OperationError(title: "Failed to delete machine", detail: error.localizedDescription)
        }
    }

    /// Create a machine from an image. Honors registry mirrors (with retag back to
    /// the canonical reference). Assembles the config inline rather than via the
    /// CLI's `machineConfigFromFlags`, whose ArgumentParser `Flags` types crash
    /// when constructed outside of command-line parsing.
    func create(
        image: String,
        name: String?,
        cpus: Int?,
        memory: String?,
        homeMount: String?,
        setAsDefault: Bool,
        noBoot: Bool
    ) async {
        let trimmedImage = image.trimmingCharacters(in: .whitespaces)
        guard !trimmedImage.isEmpty else { return }

        lastError = nil
        var progress = OperationProgress()
        progress.beginPhase("Fetching image…")
        creating = progress
        defer { creating = nil }

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

            // Fetch the image (mirror-aware; retagged to canonical reference).
            let fetchTask = await coordinator.startTask()
            let img = try await MirrorPull.pull(
                originalReference: trimmedImage,
                platform: platform,
                config: config,
                progressUpdate: ProgressTaskCoordinator.handler(for: fetchTask, from: progressHandler))

            // Unpack into a create snapshot before use.
            let unpackTask = await coordinator.startTask()
            creating?.beginPhase("Unpacking image…")
            _ = try await img.getCreateSnapshot(
                platform: platform,
                progressUpdate: ProgressTaskCoordinator.handler(for: unpackTask, from: progressHandler))

            // Determine the machine id (auto-derive from the canonical image when blank).
            let id = try machineID(name: name, image: img.reference)
            try Utility.validEntityName(id)

            let userSetup = UserSetup(username: NSUserName(), uid: getuid(), gid: getgid())
            let machineConfig = try MachineConfiguration(
                id: id,
                image: img.description,
                platform: platform,
                userSetup: userSetup)

            // resources is optional; the machine setup artifact is fetched by an
            // internal CLI helper not available here. container falls back to its
            // built-in user provisioning when absent.
            try await client.create(configuration: machineConfig, resources: nil, bootConfig: bootConfig)

            if setAsDefault {
                try await client.setDefault(id: id)
            }
            if !noBoot {
                _ = try await client.boot(id: id)
            }
            await refresh()
        } catch {
            lastError = OperationError(title: "Failed to create machine", detail: error.localizedDescription)
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

    private var progressHandler: ProgressUpdateHandler {
        { [weak self] events in
            await self?.applyProgress(events)
        }
    }

    private func applyProgress(_ events: [ProgressUpdateEvent]) {
        guard creating != nil else { return }
        creating?.apply(events)
    }
}
