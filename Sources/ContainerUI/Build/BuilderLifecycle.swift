import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

/// Manages the shared "buildkit" builder container that every build runs against.
///
/// `container build` reaches BuildKit by dialing a long-lived helper container
/// (id `"buildkit"`) over vsock; that container runs `container-builder-shim`,
/// which hosts buildkitd. The upstream `BuilderStart.start(...)` that creates it
/// is `internal`, so we replicate the essential path here using the public
/// `ContainerClient` / `ClientImage` / `ClientKernel` / `NetworkClient` APIs.
///
/// This is the build-side analog of `ContainerCreateEngine`: it fetches the
/// builder image mirror-aware (the image lives on ghcr.io, which many networks
/// can't reach directly — `MirrorPull.fetchInfraImage` adds the blessed ghcr
/// fallbacks), then creates and boots the container.
enum BuilderLifecycle {
    private static let log = Logger(label: "icontainu.builder")

    /// Container id of the shared builder. Matches `Builder.builderContainerId`.
    static let containerID = "buildkit"

    /// Vsock port the builder-shim listens on. Matches the CLI's default.
    static let vsockPort: UInt32 = 8088

    /// Coarse builder state for the status card.
    enum State: Equatable {
        case absent
        case stopped
        case running
        case stopping
    }

    /// Current builder state, or `.absent` when the query fails / it doesn't exist.
    static func status() async -> State {
        let client = ContainerClient()
        guard let snapshot = try? await client.get(id: containerID) else { return .absent }
        switch snapshot.status {
        case .running: return .running
        case .stopped: return .stopped
        case .stopping: return .stopping
        case .unknown: return .absent
        }
    }

    /// Ensure a running builder exists. A running builder is reused as-is; a
    /// stopped one is started; otherwise the container is created and booted.
    ///
    /// `progressUpdate` receives the fetch/unpack phases of the builder image
    /// (the first build on a fresh machine pulls a few hundred MB of BuildKit).
    static func ensureRunning(
        config: ContainerSystemConfig,
        progressUpdate: @escaping ProgressUpdateHandler
    ) async throws {
        let client = ContainerClient()

        // Reuse or restart an existing builder before creating a new one. Unlike
        // the CLI we don't recreate on a cpu/memory/image mismatch — a builder the
        // user already has is good enough for MVP; changing its resources is a
        // future "builder settings" concern.
        if let existing = try? await client.get(id: containerID) {
            switch existing.status {
            case .running:
                return
            case .stopped:
                log.info("starting existing builder")
                let process = try await client.bootstrap(id: containerID, stdio: [nil, nil, nil])
                try await process.start()
                return
            case .stopping:
                throw ContainerizationError(
                    .invalidState,
                    message: "The builder is stopping. Wait until it has fully stopped, then try again.")
            case .unknown:
                break
            }
        }

        // The builder always runs arm64 (amd64 targets build through Rosetta/QEMU
        // inside it), so fetch the arm64 variant of the builder image.
        let builderImage = config.build.image
        let builderPlatform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")

        // Exports mount: buildkitd writes the built OCI tar under <appRoot>/builder/,
        // shared into the container over virtiofs. "builder" matches the CLI's
        // `BuilderCommand.builderResourceDir` (internal, so inlined here).
        let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let exportsMount = systemHealth.appRoot
            .appendingPathComponent("builder")
            .path
        if !FileManager.default.fileExists(atPath: exportsMount) {
            try FileManager.default.createDirectory(
                atPath: exportsMount, withIntermediateDirectories: true)
        }

        // Mirror-aware fetch (+ blessed ghcr fallback) then unpack — the builder
        // image is infrastructure, so it must be obtainable on a fresh install with
        // no user mirror configured, exactly like the vminit init image.
        let image = try await MirrorPull.fetchInfraImage(
            originalReference: builderImage,
            platform: builderPlatform,
            config: config,
            progressUpdate: progressUpdate)
        _ = try await image.getCreateSnapshot(platform: builderPlatform, progressUpdate: progressUpdate)

        // Rosetta on → shim omits --enable-qemu (uses Rosetta for amd64); off → QEMU.
        let useRosetta = config.build.rosetta
        let shimArguments = ["--debug", "--vsock", useRosetta ? nil : "--enable-qemu"].compactMap { $0 }

        let imageDesc = ImageDescription(reference: builderImage, descriptor: image.descriptor)
        let environment = (try? await image.config(for: builderPlatform).config?.env) ?? []

        let processConfig = ProcessConfiguration(
            executable: "/usr/local/bin/container-builder-shim",
            arguments: shimArguments,
            environment: environment,
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0))

        var containerConfig = ContainerConfiguration(
            id: containerID, image: imageDesc, process: processConfig)
        containerConfig.labels = [
            ResourceLabelKeys.plugin: "builder",
            ResourceLabelKeys.role: ResourceRoleValues.builder,
        ]
        containerConfig.capAdd = ["ALL"]
        containerConfig.mounts = [
            .init(type: .tmpfs, source: "", destination: "/run", options: []),
            .init(
                type: .virtiofs, source: exportsMount,
                destination: "/var/lib/container-builder-shim/exports", options: []),
        ]
        containerConfig.rosetta = useRosetta
        // Apply builder resources. Hardcoded generously (6 GB / 4 CPU) for now to
        // rule out OOM while diagnosing the gRPC-stream-cancellations; the config
        // override isn't reaching the builder because ConfigurationLoader reads
        // appRoot, not ~/.config/container. TODO: restore config-driven values
        // once config loading is wired to the user-editable layer.
        containerConfig.resources = try Parser.resources(
            cpus: 4, memory: "6144MB",
            defaultCPUs: config.build.cpus,
            defaultMemory: config.build.memory)

        let networkClient = NetworkClient()
        guard let defaultNetwork = try await networkClient.builtin else {
            throw ContainerizationError(.invalidState, message: "The default network is not present.")
        }
        containerConfig.networks = [
            AttachmentConfiguration(
                network: defaultNetwork.id,
                options: AttachmentOptions(hostname: containerID))
        ]

        let kernel = try await ClientKernel.getDefaultKernel(for: .current)

        log.info("creating builder container", metadata: ["image": "\(builderImage)"])
        try await client.create(configuration: containerConfig, options: .default, kernel: kernel)

        let process = try await client.bootstrap(id: containerID, stdio: [nil, nil, nil])
        try await process.start()
        log.info("builder started")
    }

    /// Stop the builder (keeps it around so the next build restarts it fast).
    static func stop() async throws {
        try await ContainerClient().stop(id: containerID)
    }

    /// Delete the builder entirely: stop, let it settle, then force-remove.
    /// Waiting out the `.stopping` transition matters right after a build - a
    /// force-delete racing a still-stopping container (buildkitd flushing) fails.
    static func delete() async throws {
        let client = ContainerClient()
        try? await client.stop(id: containerID)
        for _ in 0..<20 {
            if await status() != .stopping { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        try await client.delete(id: containerID, force: true)
    }
}
