import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerPersistence
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import NIOCore
import NIOPosix
import TerminalProgress

/// Shared image-build engine. Drives `container`'s BuildKit backend end to end:
/// ensure the builder container is up, stream a build, and land the result as a
/// local image. This is the build-side analog of `ContainerCreateEngine` — the
/// independent Build section and (later) Compose `build:` both call `build(...)`.
///
/// Progress/logging note: `ContainerBuild.BuildPipeline` writes BuildKit's console
/// output to `config.terminal?.handle ?? FileHandle.standardError`. There is no
/// per-handler injection point, so to capture the log we hand it a real PTY (via
/// `Terminal.create()`) and read the other end — a plain `Pipe` won't do because
/// `Builder.build` calls `terminal.size` (a TTY ioctl) and installs a SIGWINCH
/// handler on it.
enum BuildEngine {
    private static let log = Logger(label: "icontainu.build")

    /// BUG workaround (apple/container#735): BuildKit rejects Dockerfiles ≥ 16 KiB.
    /// Fail early with a clear message rather than deep in the gRPC stream.
    private static let maxDockerfileSize = 16 * 1024

    enum BuildError: Error, CustomStringConvertible {
        case dockerfileTooLarge(Int)
        case noTags
        case loadProducedNoImage
        case archiveRejectedMembers([String])

        var description: String {
            switch self {
            case .dockerfileTooLarge(let size):
                return
                    "Dockerfile is \(size) bytes; the maximum is \(maxDockerfileSize) bytes (apple/container#735)."
            case .noTags:
                return "At least one image tag is required to build."
            case .loadProducedNoImage:
                return "The build finished but produced no image to load."
            case .archiveRejectedMembers(let members):
                return "The built image archive contained invalid members: \(members.joined(separator: ", "))."
            }
        }
    }

    /// Build an image from `spec`, reporting phase changes through `beginPhase`
    /// (same contract as `ContainerCreateEngine.create`) and streaming BuildKit's
    /// console output line-by-line through `onLog`.
    ///
    /// Returns the normalized tags that were applied to the built image.
    @discardableResult
    static func build(
        spec: BuildSpec,
        beginPhase: @escaping @Sendable (String) async -> ProgressUpdateHandler,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> [String] {
        guard !spec.tags.isEmpty else { throw BuildError.noTags }

        let config = try await SystemConfig.load()

        // Tag the built image under EXACTLY the reference the create/run path will
        // look it up by — `ClientImage.normalizeReference`, the same normalization
        // `MirrorPull.fetch` applies. `Reference.normalize()` alone is not enough:
        // for a bare name with a repository segment (e.g. "icontainu/foo") it
        // leaves the domain unset (stored as "icontainu/foo"), while the lookup
        // prepends the default registry ("docker.io/icontainu/foo"). That mismatch
        // makes a locally-built image invisible to compose Up, which then tries to
        // pull the local-only tag from docker.io and fails. Aligning both on
        // `normalizeReference` keeps the stored name and the lookup name identical.
        let imageNames: [String] = try spec.tags.map { name in
            try ClientImage.normalizeReference(name, containerSystemConfig: config)
        }

        let dockerfileData = try Data(contentsOf: spec.dockerfilePath)
        guard dockerfileData.count < maxDockerfileSize else {
            throw BuildError.dockerfileTooLarge(dockerfileData.count)
        }
        let dockerignoreData = try? Data(
            contentsOf: spec.dockerfilePath.appendingPathExtension("dockerignore"))

        // MARK: 0. Pre-fetch every `FROM` base image through the registry mirror.
        // The builder's internal image resolver pulls `FROM` images directly from
        // the registry (it does NOT use IcontainU's mirror), so on networks where
        // docker.io is unreachable that pull times out (HTTPClientError.connectTimeout).
        // Pulling them local-first through `MirrorPull` - the same path normal image
        // pulls use - lets the resolver find each base image in the local store and
        // skip the network entirely.
        try await prefetchBaseImages(
            dockerfileData: dockerfileData, spec: spec, config: config, beginPhase: beginPhase)

        // MARK: 1. Ensure the builder is running, then dial it.
        let prepareHandler = await beginPhase(String(localized: "Preparing builder…"))
        try await BuilderLifecycle.ensureRunning(config: config, progressUpdate: prepareHandler)
        try Task.checkCancellation()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        // `Builder.build` shuts `group` down itself on the success path; we shut it
        // down on every early-exit / error path via the catch below. Async only —
        // `syncShutdownGracefully` traps in an async context. A double-shutdown is
        // harmless (the second call throws, swallowed by try?).
        do {
        // Dial with a bounded retry: a just-created builder needs a moment before
        // the shim is listening on vsock. Mirrors the CLI's start→sleep→redial loop.
        let builder = try await dialBuilder(group: group)

        // MARK: 2. Set up PTY log capture.
        let (parent, child) = try Terminal.create()
        let logReader = Task.detached {
            await streamLog(from: parent.handle, onLog: onLog)
        }
        defer {
            // Close the CHILD end first: the detached reader is blocked in
            // `parent.handle.availableData`, which holds FileHandle's internal
            // lock. Closing `parent` directly would deadlock on that lock (the
            // classic FileHandle close-vs-read deadlock) — this is exactly what
            // froze the UI on failed builds: `builder.build` threw, this defer
            // hung on `parent.handle.close()`, and `activeBuild` never cleared.
            // Closing `child` collapses the PTY, the blocked read returns EOF,
            // the reader exits and releases the lock, then closing `parent` is
            // safe. (On success the explicit child close below already did this;
            // a second close just throws and is swallowed.)
            try? child.handle.close()
            logReader.cancel()
            try? parent.handle.close()
        }

        // MARK: 3. Build.
        let buildHandler = await beginPhase(String(localized: "Building image…"))
        await buildHandler([.setDescription(String(localized: "Building image…"))])

        let secretsData: [String: Data] = try spec.secrets.mapValues { source in
            switch source {
            case .env(let name):
                return Data((ProcessInfo.processInfo.environment[name] ?? "").utf8)
            case .file(let url):
                return try Data(contentsOf: url)
            }
        }

        // Export a single OCI tar under <appRoot>/builder/<buildID>/out.tar. The
        // builder writes there over the virtiofs mount; we load it back afterward.
        let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let buildID = UUID().uuidString
        let exportDir = systemHealth.appRoot
            .appendingPathComponent("builder")
            .appendingPathComponent(buildID)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportDir) }
        let outTar = exportDir.appendingPathComponent("out.tar")

        var ociExport = try Builder.BuildExport(from: "type=oci")
        ociExport.destination = outTar

        let buildConfig = Builder.BuildConfig(
            buildID: buildID,
            contentStore: RemoteContentStoreClient(),
            buildArgs: spec.buildArgs,
            secrets: secretsData,
            contextDir: spec.contextDir.path,
            dockerfile: dockerfileData,
            dockerignore: dockerignoreData,
            labels: spec.labels,
            noCache: spec.noCache,
            platforms: spec.platforms,
            terminal: child,
            tags: imageNames,
            target: spec.target,
            quiet: false,
            exports: [ociExport],
            cacheIn: [],
            cacheOut: [],
            pull: spec.pull,
            containerSystemConfig: config)

        // `Builder.build` runs the stream to completion, then shuts down `group`
        // itself on the internal `buildComplete` sentinel — so we must not
        // sync-shutdown the group again in a defer.
        try await builder.build(buildConfig)

        // Close our end of the PTY so the log reader sees EOF and drains.
        try? child.handle.close()
        try Task.checkCancellation()

        // MARK: 4. Load the built tar and tag it.
        let importHandler = await beginPhase(String(localized: "Importing image…"))
        await importHandler([.setDescription(String(localized: "Importing image…"))])

        let result = try await ClientImage.load(from: outTar.path, force: false)
        guard result.rejectedMembers.isEmpty else {
            throw BuildError.archiveRejectedMembers(result.rejectedMembers)
        }
        guard let loaded = result.images.first else {
            throw BuildError.loadProducedNoImage
        }
        try await loaded.unpack(platform: nil, progressUpdate: importHandler)
        for tag in imageNames {
            try Task.checkCancellation()
            _ = try await loaded.tag(new: tag)
        }

        log.info("build complete", metadata: ["tags": "\(imageNames)"])
        return imageNames
        } catch {
            // On any failure/cancel, `Builder.build` may not have run to its
            // internal shutdown, so release the event-loop group here (async —
            // sync shutdown traps in async contexts). Then rethrow.
            try? await group.shutdownGracefully()
            throw error
        }
    }

    // MARK: - Helpers

    /// Pull each external base image mirror-aware so the builder's resolver hits
    /// the local store. `MirrorPull.fetch` is local-first, so already-cached bases
    /// return instantly; only missing ones go out through the configured mirror.
    private static func prefetchBaseImages(
        dockerfileData: Data,
        spec: BuildSpec,
        config: ContainerSystemConfig,
        beginPhase: @escaping @Sendable (String) async -> ProgressUpdateHandler
    ) async throws {
        let bases = parseBaseImages(dockerfileData)
        guard !bases.isEmpty else { return }
        let handler = await beginPhase(String(localized: "Fetching base images…"))
        for base in bases {
            // Platforms the builder will request for this base. An explicit
            // `--platform=os/arch` pins it. An absent/variable platform
            // (`--platform=$BUILDPLATFORM` parses to nil, and $BUILDPLATFORM is the
            // builder's native arm64) means the stage runs on the host platform -
            // so pull the host platform plus every build target, covering both the
            // $BUILDPLATFORM case and the normal target-platform case.
            var platforms: Set<Platform> = []
            if let p = base.platform {
                platforms.insert(p)
            } else {
                platforms.insert(try Platform(from: "linux/\(Arch.hostArchitecture().rawValue)"))
                platforms.formUnion(spec.platforms)
            }
            for p in platforms {
                try Task.checkCancellation()
                _ = try await MirrorPull.fetch(
                    originalReference: base.reference,
                    platform: p,
                    config: config,
                    progressUpdate: handler)
            }
        }
    }

    /// Parse external image references out of a Dockerfile: `FROM <image>` and
    /// `COPY --from=<image>`. Stage names (defined by `FROM … AS <name>`) and
    /// `scratch` are excluded - a `FROM <stage>` or `COPY --from=<stage>` references
    /// an already-built stage, not a registry image, and trying to pull it would
    /// hit the registry and fail. Returns each reference plus any `--platform=`
    /// override (`$BUILDPLATFORM`/`$TARGETPLATFORM` don't parse to a `Platform`,
    /// yielding nil, which `prefetchBaseImages` handles).
    private static func parseBaseImages(
        _ dockerfileData: Data
    ) -> [(reference: String, platform: Platform?)] {
        guard let text = String(data: dockerfileData, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let tokensOf = { (line: String) in
            line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }

        // Pass 1: collect stage names from `FROM … AS <name>`.
        var stageNames = Set<String>()
        for line in lines {
            let tokens = tokensOf(line)
            guard tokens.first?.uppercased() == "FROM", tokens.count > 1 else { continue }
            if let asIdx = tokens.firstIndex(where: { $0.uppercased() == "AS" }),
                asIdx + 1 < tokens.count
            {
                stageNames.insert(tokens[asIdx + 1])
            }
        }

        // Pass 2: collect external image refs from FROM and COPY --from.
        var results: [(reference: String, platform: Platform?)] = []
        var seen = Set<String>()
        for line in lines {
            let tokens = tokensOf(line)
            guard let first = tokens.first else { continue }
            let cmd = first.uppercased()

            if cmd == "FROM", tokens.count > 1 {
                var platform: Platform? = nil
                var idx = 1
                while idx < tokens.count, tokens[idx].hasPrefix("--") {
                    if tokens[idx].lowercased().hasPrefix("--platform=") {
                        let val = String(tokens[idx].dropFirst("--platform=".count))
                        platform = try? Platform(from: val)
                    } else if tokens[idx].lowercased() == "--platform", idx + 1 < tokens.count {
                        platform = try? Platform(from: tokens[idx + 1])
                        idx += 1
                    }
                    idx += 1
                }
                guard idx < tokens.count else { continue }
                let ref = tokens[idx]
                if ref.lowercased() == "scratch" { continue }
                if stageNames.contains(ref) { continue }  // `FROM <stage>` - already built
                if seen.insert(ref).inserted {
                    results.append((reference: ref, platform: platform))
                }
            } else if cmd == "COPY" {
                // `COPY --from=<image>` where <image> is not a stage name.
                for tok in tokens where tok.lowercased().hasPrefix("--from=") {
                    let ref = String(tok.dropFirst("--from=".count))
                    if ref.lowercased() == "scratch" { continue }
                    if stageNames.contains(ref) { continue }  // `COPY --from=<stage>`
                    if seen.insert(ref).inserted {
                        results.append((reference: ref, platform: nil))
                    }
                }
            }
        }
        return results
    }

    /// Dial the builder over vsock, retrying briefly while a freshly created shim
    /// starts listening. Throws if it never comes up within the timeout.
    private static func dialBuilder(group: EventLoopGroup) async throws -> Builder {
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while true {
            do {
                let client = ContainerClient()
                let fh = try await client.dial(id: BuilderLifecycle.containerID, port: BuilderLifecycle.vsockPort)
                let builder = try Builder(socket: fh, group: group, logger: log)
                _ = try await builder.info()
                return builder
            } catch {
                try Task.checkCancellation()
                if ContinuousClock.now >= deadline {
                    throw ContainerizationError(
                        .timeout, message: "Timed out waiting for the builder to accept connections.")
                }
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Read the PTY parent end, split into lines, and forward each to `onLog`.
    /// Strips ANSI escape sequences so the log view shows plain text.
    ///
    /// Uses `FileHandle.readabilityHandler` (callback-based, non-blocking) wrapped
    /// in an `AsyncStream`, NOT the synchronous `availableData` polling loop it
    /// replaced. The old loop blocked on `availableData`, which (a) doesn't
    /// respond to `Task.cancel` and (b) throws an ObjC `NSFileHandleOperationException`
    /// ("Bad file descriptor") if the fd is closed while blocked - an ObjC
    /// exception Swift can't catch, crashing the app on every failed build.
    private static func streamLog(from handle: FileHandle, onLog: @escaping @Sendable (String) -> Void) async {
        let chunks = AsyncStream<Data> { continuation in
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }

        var buffer = Data()
        for await chunk in chunks {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    let clean = stripANSI(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    if !clean.isEmpty { onLog(clean) }
                }
            }
        }
        // Flush any trailing partial line.
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            let clean = stripANSI(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { onLog(clean) }
        }
    }

    /// Remove ANSI/VT100 escape sequences (BuildKit's TTY renderer emits cursor
    /// moves and colors). Keeps the visible text.
    private static func stripANSI(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var chars = s.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return chars.next()
        }
        while let c = next() {
            guard c == "\u{1B}" else { out.append(c); continue }
            // ESC — consume the following escape sequence.
            guard let n = chars.next() else { break }
            if n == "[" {
                // CSI: consume until a final byte in @–~ (0x40–0x7E).
                while let m = chars.next() {
                    if ("\u{40}"..."\u{7E}").contains(m) { break }
                }
            }
            // Other escapes (single char) are just dropped.
        }
        return out
    }
}
