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
    private var sessionManager: MCPSessionManager?
    private var serverTask: Task<Void, Never>?

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
        guard !isRunning else { return }

        let bridge = MCPModelBridge(
            containers: containersModel,
            images: imagesModel,
            machines: machinesModel,
            volumes: volumesModel,
            networks: networksModel,
            compose: composeModel,
            system: systemModel
        )

        let manager = MCPSessionManager(bridge: bridge, requestLog: requestLog)
        sessionManager = manager

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
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
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        do {
            let ch = try await bootstrap.bind(
                host: settings.bindAddress,
                port: settings.port
            ).get()
            self.channel = ch
            isRunning = true
            lastError = nil

            serverTask = Task {
                do {
                    try await ch.closeFuture.get()
                } catch {
                    await MainActor.run {
                        self.isRunning = false
                        self.lastError = error.localizedDescription
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() async {
        guard isRunning else { return }
        serverTask?.cancel()
        serverTask = nil
        try? await channel?.close()
        channel = nil
        sessionManager = nil
        isRunning = false
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
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil

            nonisolated(unsafe) let ctx = context
            nonisolated(unsafe) let self_ = self
            Task {
                await self_.handleRequest(state: state, context: ctx)
            }
        }
    }

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = String(head.uri.split(separator: "?").first ?? Substring(head.uri))

        guard path == MCPConstants.endpoint else {
            writeErrorResponse(status: .notFound, body: "Not Found", version: head.version, context: context)
            return
        }

        // API Key authentication
        let authHeader = head.headers.first(name: "Authorization")
        guard let auth = authHeader, auth.hasPrefix("Bearer ") else {
            writeErrorResponse(status: .unauthorized, body: "Unauthorized", version: head.version, context: context)
            return
        }
        let token = String(auth.dropFirst(7))
        guard settings.validateKey(token) else {
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

            // Stream SSE events
            Task {
                do {
                    for try await chunk in stream {
                        eventLoop.execute {
                            var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                            buffer.writeBytes(chunk)
                            ctx.writeAndFlush(
                                self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                        }
                    }
                } catch {
                    // Stream error — close connection
                }
                eventLoop.execute {
                    ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }
            }

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
        context.eventLoop.execute {
            var head = HTTPResponseHead(version: version, status: status)
            head.headers.add(name: "Content-Type", value: "text/plain")
            head.headers.add(name: "Content-Length", value: "\(bodyData.count)")
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)

            var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
            buffer.writeBytes(bodyData)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
