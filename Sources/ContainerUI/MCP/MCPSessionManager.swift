import Foundation
import Logging
import MCP

actor MCPSessionManager {
    private var sessions: [String: SessionContext] = [:]
    private let toolRegistry: MCPToolRegistry
    private let requestLog: MCPRequestLog
    private let logger: Logger
    private let bindAddress: String
    private var reaperTask: Task<Void, Never>?

    /// Validation pipeline reused for every new session. Origin validation is
    /// loosened when bound to all interfaces — the default `OriginValidator
    /// .localhost()` would otherwise reject every non-localhost Host header,
    /// silently breaking the "0.0.0.0" UI option.
    private lazy var validationPipeline: any HTTPRequestValidationPipeline = {
        let origin: OriginValidator
        if bindAddress == "0.0.0.0" {
            origin = .disabled
        } else {
            origin = .localhost()
        }
        return StandardValidationPipeline(validators: [
            origin,
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])
    }()

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    /// Async factory. The reaper Task can't be started in init — init is
    /// nonisolated, but assigning to `reaperTask` (a mutable stored property)
    /// and capturing `self` in the Task closure both require isolation. So
    /// init sets the immutable fields, and `create()` starts the reaper from
    /// an isolated context.
    static func create(
        bridge: MCPModelBridge,
        requestLog: MCPRequestLog,
        bindAddress: String
    ) async -> MCPSessionManager {
        let manager = MCPSessionManager(bridge: bridge, requestLog: requestLog, bindAddress: bindAddress)
        await manager.startReaping()
        return manager
    }

    private init(bridge: MCPModelBridge, requestLog: MCPRequestLog, bindAddress: String) {
        self.toolRegistry = MCPToolRegistry(bridge: bridge, requestLog: requestLog)
        self.requestLog = requestLog
        self.logger = Logger(label: "mcp.session")
        self.bindAddress = bindAddress
    }

    func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        // Route to existing session
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)

            // Clean up on successful DELETE
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }

            return response
        }

        // No session — check for initialize request
        if request.method.uppercased() == "POST",
           let body = request.body,
           isInitializeRequest(body)
        {
            return await createSessionAndHandle(request)
        }

        // No session and not initialize
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    func activeSessionCount() -> Int {
        sessions.count
    }

    /// Stop the reaper and disconnect every session. Called by MCPServerManager
    /// on stop() so transports don't outlive the server.
    func stop() async {
        reaperTask?.cancel()
        reaperTask = nil
        for (_, ctx) in sessions {
            await ctx.transport.disconnect()
        }
        sessions.removeAll()
    }

    private func isInitializeRequest(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String
        else {
            return false
        }
        return method == "initialize"
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: validationPipeline,
            retryInterval: nil,
            logger: logger
        )

        do {
            let server = Server(
                name: "IcontainU",
                version: "1.0.0",
                capabilities: .init(tools: .init(listChanged: true))
            )
            await toolRegistry.registerHandlers(on: server)
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)

            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    /// Periodically evict sessions idle longer than `sessionTimeout`. Without
    /// this, a client that initializes and disconnects without DELETE leaks a
    /// Server + Transport (and its event store) forever.
    private func startReaping() {
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await self?.sweepExpiredSessions()
            }
        }
    }

    private func sweepExpiredSessions() async {
        let cutoff = Date().addingTimeInterval(-MCPConstants.sessionTimeout)
        let expired = sessions.filter { $0.value.lastAccessedAt < cutoff }
        guard !expired.isEmpty else { return }
        for (id, ctx) in expired {
            await ctx.transport.disconnect()
            sessions.removeValue(forKey: id)
        }
        logger.info("Reaped \(expired.count) idle MCP session(s)")
    }
}

private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}
