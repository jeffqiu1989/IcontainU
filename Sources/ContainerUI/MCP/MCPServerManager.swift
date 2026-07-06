import Foundation
import Logging
import MCP
import NIOCore
import NIOPosix
import NIOHTTP1
import Observation

@Observable
@MainActor
final class MCPServerManager {
    private(set) var isRunning = false
    private(set) var lastError: String?

    let settings: MCPSettings
    let requestLog: MCPRequestLog

    private var channel: Channel?
    private var group: MultiThreadedEventLoopGroup?
    private var sessionManager: MCPSessionManager?
    private var serverTask: Task<Void, Never>?

    /// The in-flight lifecycle operation (start/stop), if any. `isRunning` is
    /// flipped only after bind/teardown completes, so the `!isRunning` guard
    /// alone can't prevent two concurrent `start()` calls from both passing it
    /// during the await window — that race leaked an EventLoopGroup + session
    /// reaper on every collision. Await this task at the top of every lifecycle
    /// method to serialize them.
    private var lifecycleTask: Task<Void, Never>?
    /// Error captured by `performStart`, re-thrown by `start()` for `try` callers.
    private var startError: Error?

    private let containersModel: ContainersModel
    private let imagesModel: ImagesModel
    private let machinesModel: MachinesModel
    private let volumesModel: VolumesModel
    private let networksModel: NetworksModel
    private let composeModel: ComposeModel
    private let systemModel: SystemModel

    init(
        settings: MCPSettings,
        requestLog: MCPRequestLog,
        containersModel: ContainersModel,
        imagesModel: ImagesModel,
        machinesModel: MachinesModel,
        volumesModel: VolumesModel,
        networksModel: NetworksModel,
        composeModel: ComposeModel,
        systemModel: SystemModel
    ) {
        self.settings = settings
        self.requestLog = requestLog
        self.containersModel = containersModel
        self.imagesModel = imagesModel
        self.machinesModel = machinesModel
        self.volumesModel = volumesModel
        self.networksModel = networksModel
        self.composeModel = composeModel
        self.systemModel = systemModel
    }

    func start() async throws {
        // Serialize against any in-flight start/stop so the `!isRunning` guard
        // (flipped only after bind completes) can't be passed twice.
        await lifecycleTask?.value
        lifecycleTask = nil
        guard !isRunning else { return }

        startError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        lifecycleTask = task
        await task.value
        if let error = startError { throw error }
    }

    private func performStart() async {
        let bridge = MCPModelBridge(
            containers: containersModel,
            images: imagesModel,
            machines: machinesModel,
            volumes: volumesModel,
            networks: networksModel,
            compose: composeModel,
            system: systemModel
        )

        let manager = await MCPSessionManager.create(
            bridge: bridge,
            requestLog: requestLog,
            bindAddress: settings.bindAddress
        )
        sessionManager = manager

        // Own the group so stop() can tear it down. A previous version left it as
        // a local and leaked System.coreCount threads on every start/stop cycle.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = group
        let settingsRef = settings

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        MCPHTTPHandler(sessionManager: manager, settings: settingsRef)
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let ch = try await bootstrap.bind(
                host: settings.bindAddress,
                port: settings.port
            ).get()
            self.channel = ch
            isRunning = true
            lastError = nil

            // Await channel close (from stop() or external). Reset isRunning on
            // completion either way — do NOT cancel this Task in stop(), since
            // cancellation would surface as a spurious lastError.
            serverTask = Task { [weak self] in
                try? await ch.closeFuture.get()
                await MainActor.run { self?.isRunning = false }
            }
        } catch {
            // Bind failed — tear down the group we just created so its threads
            // don't leak, and stop the session manager (which started its
            // reaper Task in init) before dropping the reference.
            await sessionManager?.stop()
            sessionManager = nil
            await Self.shutdownGracefully(group)
            self.group = nil
            lastError = error.localizedDescription
            startError = error
        }
    }

    func stop() async {
        await lifecycleTask?.value
        lifecycleTask = nil
        guard isRunning else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStop()
        }
        lifecycleTask = task
        await task.value
    }

    private func performStop() async {
        // Close the server channel (stops accepting), then shut down the group.
        // group.shutdownGracefully closes every child channel still attached to
        // it, so in-flight client connections are torn down too — not just the
        // listening socket.
        try? await channel?.close()
        channel = nil
        if let group {
            await Self.shutdownGracefully(group)
            self.group = nil
        }
        // Tear down sessions (disconnects transports, cancels the reaper Task)
        // before dropping the reference — otherwise the reaper would outlive the
        // server and keep touching disconnected transports.
        await sessionManager?.stop()
        sessionManager = nil
        isRunning = false
        // serverTask will exit on its own once closeFuture completes; we don't
        // need to await or cancel it.
        serverTask = nil
    }

    /// Stop then start, so a changed port or bind address takes effect. Waits for
    /// any in-flight start/stop first, so a config change made during startup is
    /// applied rather than silently dropped (the old `guard isRunning` bailed
    /// because isRunning is false throughout the start window). A no-op when not
    /// running — the new values are already picked up on the next start.
    func restart() async throws {
        await lifecycleTask?.value
        lifecycleTask = nil
        if isRunning {
            await stop()
        }
        try await start()
    }

    private static func shutdownGracefully(_ group: EventLoopGroup) async {
        await withCheckedContinuation { continuation in
            group.shutdownGracefully { _ in continuation.resume() }
        }
    }
}

// MARK: - NIO HTTP Handler

private final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let sessionManager: MCPSessionManager
    private let settings: MCPSettings

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var requestState: RequestState?
    /// SSE stream Tasks spawned for this channel's responses. Cancelled when the
    /// channel goes inactive so a dead connection stops writing.
    private var streamTasks: [Task<Void, Never>] = []

    init(sessionManager: MCPSessionManager, settings: MCPSettings) {
        self.sessionManager = sessionManager
        self.settings = settings
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )

        case .body(var buffer):
            guard let state = requestState else { return }
            // Enforce the body size limit before accumulating — without this a
            // malicious client could exhaust memory by streaming a huge POST.
            let projected = state.bodyBuffer.readableBytes + buffer.readableBytes
            if projected > MCPConstants.maxRequestBodyBytes {
                requestState = nil
                writeErrorResponse(
                    status: HTTPResponseStatus(statusCode: 413),
                    body: "Payload Too Large",
                    version: state.head.version,
                    context: context
                )
                context.close(promise: nil)
                return
            }
            requestState?.bodyBuffer.writeBuffer(&buffer)

        case .end:
            guard let state = requestState else { return }
            requestState = nil

            nonisolated(unsafe) let ctx = context
            Task {
                await self.handleRequest(state: state, context: ctx)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Channel closed — cancel any in-flight SSE stream Tasks so they stop
        // writing to a dead context.
        for task in streamTasks { task.cancel() }
        streamTasks.removeAll()
    }

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = String(head.uri.split(separator: "?").first ?? Substring(head.uri))

        guard path == MCPConstants.endpoint else {
            writeErrorResponse(status: .notFound, body: "Not Found", version: head.version, context: context)
            return
        }

        // API Key authentication. settings is @MainActor-isolated, so hop to
        // MainActor for the read.
        let authHeader = head.headers.first(name: "Authorization")
        guard let auth = authHeader, auth.hasPrefix("Bearer ") else {
            writeErrorResponse(status: .unauthorized, body: "Unauthorized", version: head.version, context: context)
            return
        }
        let token = String(auth.dropFirst(7))
        let valid = await MainActor.run { settings.validateKey(token) }
        guard valid else {
            writeErrorResponse(status: .unauthorized, body: "Invalid API key", version: head.version, context: context)
            return
        }

        // Build MCP.HTTPRequest
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if state.bodyBuffer.readableBytes > 0 {
            body = Data(state.bodyBuffer.readableBytesView)
        } else {
            body = nil
        }

        let httpRequest = HTTPRequest(
            method: head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )

        let response = await sessionManager.handleRequest(httpRequest)
        writeResponse(response, version: head.version, context: context)
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop

        switch response {
        case .stream(let stream, _):
            // Write headers for SSE stream
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode)
                )
                for (name, value) in response.headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }

            // Stream SSE events. Track the Task so channelInactive can cancel it.
            let task = Task {
                do {
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        eventLoop.execute {
                            var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                            buffer.writeBytes(chunk)
                            ctx.writeAndFlush(
                                self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                        }
                    }
                } catch {
                    // Stream error — fall through to close the response.
                }
                if !Task.isCancelled {
                    eventLoop.execute {
                        ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                    }
                }
            }
            eventLoop.execute { self.streamTasks.append(task) }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode)
                )
                for (name, value) in response.headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)

                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }

                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }

    private func writeErrorResponse(
        status: HTTPResponseStatus,
        body: String,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) {
        let bodyData = Data(body.utf8)
        nonisolated(unsafe) let ctx = context
        context.eventLoop.execute {
            var head = HTTPResponseHead(version: version, status: status)
            head.headers.add(name: "Content-Type", value: "text/plain")
            head.headers.add(name: "Content-Length", value: "\(bodyData.count)")
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)

            var buffer = ctx.channel.allocator.buffer(capacity: bodyData.count)
            buffer.writeBytes(bodyData)
            ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
