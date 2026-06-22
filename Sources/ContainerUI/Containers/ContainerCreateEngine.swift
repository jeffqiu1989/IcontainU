import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

/// Creates and starts a container from a `ContainerCreateSpec`, mirroring what
/// `container run -d` does: assemble the configuration via the shared
/// `Utility.containerConfigFromFlags`, create it, then bootstrap and start
/// detached. Registry mirrors are honored by pre-pulling the image.
enum ContainerCreateEngine {
    private static let log = Logger(label: "icontainu.create")

    /// Build, create, and start the container. Returns the resulting container id.
    ///
    /// `beginPhase` is invoked at each progress phase boundary with a label; it
    /// returns the handler to use for that phase. This lets the caller relabel
    /// the UI and coordinate phases (dropping stale events) without the engine
    /// knowing about UI state.
    static func create(
        spec: ContainerCreateSpec,
        beginPhase: @Sendable (String) async -> ProgressUpdateHandler
    ) async throws -> String {
        let config = try await SystemConfig.load()
        let client = ContainerClient()

        let id = Utility.createContainerID(name: spec.name)
        try Utility.validEntityName(id)

        // Log every resolved input so a misconfigured run is obvious in the
        // `swift run IcontainU` console — this is the primary debugging aid.
        log.info(
            "creating container",
            metadata: [
                "id": "\(id)",
                "image": "\(spec.image)",
                "command": "\(spec.command)",
                "publishPorts": "\(spec.publishPorts)",
                "env": "\(spec.env)",
                "volumes": "\(spec.volumes)",
                "network": "\(spec.networks.isEmpty ? "<default>" : spec.networks.joined(separator: ","))",
                "autoRemove": "\(spec.autoRemove)",
                "ssh": "\(spec.ssh)",
            ])

        // client.get throws .notFound when the container doesn't exist,
        // so we catch that and re-throw any other error.
        do {
            _ = try await client.get(id: id)
            throw ContainerUIError.alreadyExists(id)
        } catch let error as ContainerizationError where error.code == .notFound {
            // Container does not exist — safe to proceed.
        }

        // Pre-pull through any configured mirror so the fetch inside
        // containerConfigFromFlags finds the (mirror-free) image locally.
        let platform = try? Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")
        log.debug("pre-pulling image via mirror store", metadata: ["reference": "\(spec.image)"])
        let fetchHandler = await beginPhase("Fetching image…")
        let image = try await MirrorPull.pull(
            originalReference: spec.image,
            platform: platform,
            config: config,
            progressUpdate: fetchHandler)
        log.debug("image ready", metadata: ["reference": "\(image.reference)"])

        let flags = makeFlags(spec: spec)
        log.debug(
            "assembled flags",
            metadata: [
                "process.env": "\(flags.process.env)",
                "management.publishPorts": "\(flags.management.publishPorts)",
                "management.volumes": "\(flags.management.volumes)",
                "management.networks": "\(flags.management.networks)",
                "management.remove": "\(flags.management.remove)",
                "management.ssh": "\(flags.management.ssh)",
            ])

        // Empty command means "use the image default" (entrypoint + image cmd).
        // A non-empty command is passed as arguments: appended to the entrypoint
        // if the image has one, otherwise it is the command to run — standard
        // Docker/OCI semantics, handled server-side by Parser.process.
        let prepareHandler = await beginPhase("Preparing container…")
        let (containerConfig, kernel, initImage) = try await Utility.containerConfigFromFlags(
            id: id,
            image: image.reference,
            arguments: spec.command,
            process: flags.process,
            management: flags.management,
            resource: flags.resource,
            registry: flags.registry,
            imageFetch: flags.imageFetch,
            containerSystemConfig: config,
            progressUpdate: prepareHandler,
            log: log)

        let options = ContainerCreateOptions(autoRemove: spec.autoRemove)
        log.info("creating container record", metadata: ["id": "\(id)"])
        try await client.create(
            configuration: containerConfig, options: options, kernel: kernel, initImage: initImage)

        // Detached start: no stdio attached.
        log.info("starting container detached", metadata: ["id": "\(id)"])
        let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
        try await process.start()
        log.info("container started", metadata: ["id": "\(id)"])
        return id
    }

    // MARK: - Flag assembly

    private struct Flags {
        var process: ContainerAPIClient.Flags.Process
        var management: ContainerAPIClient.Flags.Management
        var resource: ContainerAPIClient.Flags.Resource
        var registry: ContainerAPIClient.Flags.Registry
        var imageFetch: ContainerAPIClient.Flags.ImageFetch
    }

    private static func makeFlags(spec: ContainerCreateSpec) -> Flags {
        // IMPORTANT: build these via their full memberwise initializers, never the
        // empty `init()` + property assignment. ArgumentParser's `@Option var x = []`
        // default is parser metadata, not stored state — a struct made with `init()`
        // traps with "Can't read a value from a parsable argument definition" the
        // moment any unassigned property is read. The memberwise inits assign every
        // property (including the nested `dns` OptionGroup), matching a parsed CLI run.
        let process = ContainerAPIClient.Flags.Process(
            cwd: nil,
            env: spec.env,
            envFile: [],
            gid: nil,
            interactive: false,
            tty: false,
            uid: nil,
            ulimits: [],
            user: nil)

        let management = ContainerAPIClient.Flags.Management(
            arch: Arch.hostArchitecture().rawValue,
            capAdd: [],
            capDrop: [],
            cidfile: "",
            detach: true,
            dns: ContainerAPIClient.Flags.DNS(
                domain: nil, nameservers: [], options: [], searchDomains: []),
            dnsDisabled: false,
            entrypoint: nil,
            initImage: nil,
            kernel: nil,
            labels: [],
            mounts: [],
            name: spec.name,
            networks: spec.networks,
            os: "linux",
            platform: nil,
            publishPorts: spec.publishPorts,
            publishSockets: [],
            readOnly: false,
            remove: spec.autoRemove,
            rosetta: false,
            runtime: nil,
            ssh: spec.ssh,
            shmSize: nil,
            tmpFs: [],
            useInit: false,
            virtualization: false,
            volumes: spec.volumes)

        return Flags(
            process: process,
            management: management,
            resource: ContainerAPIClient.Flags.Resource(cpus: nil, memory: nil),
            registry: ContainerAPIClient.Flags.Registry(scheme: "auto"),
            imageFetch: ContainerAPIClient.Flags.ImageFetch(maxConcurrentDownloads: 3))
    }
}

enum ContainerUIError: LocalizedError {
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let id): "A container named \"\(id)\" already exists."
        }
    }
}
