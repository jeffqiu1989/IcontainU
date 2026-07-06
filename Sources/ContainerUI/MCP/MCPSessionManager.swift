import Foundation
import Logging
import MCP

actor MCPSessionManager {
    private var sessions: [String: SessionContext] = [:]
    private let toolRegistry: MCPToolRegistry
    private let requestLog: MCPRequestLog
    private let logger: Logger

    struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    init(bridge: MCPModelBridge, requestLog: MCPRequestLog) {
        self.toolRegistry = MCPToolRegistry(bridge: bridge, requestLog: requestLog)
        self.requestLog = requestLog
        self.logger = Logger(label: "mcp.session")
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
}

private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}
