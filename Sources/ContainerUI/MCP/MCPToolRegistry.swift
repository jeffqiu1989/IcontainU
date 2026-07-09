import Foundation
import MCP

/// Per-session mutable holder for the authenticated key name. MCPSessionManager
/// sets it when a session is created; the CallTool handler reads it when
/// recording a log entry. One holder per session, so there's no cross-session
/// race on `keyName`.
final class MCPKeyHolder: @unchecked Sendable {
    var keyName: String?
    init(_ keyName: String?) { self.keyName = keyName }
}

struct MCPToolRegistry: Sendable {
    let bridge: MCPModelBridge
    let requestLog: MCPRequestLog

    func allTools() -> [Tool] {
        ContainerTools.toolDefinitions()
            + ImageTools.toolDefinitions()
            + MachineTools.toolDefinitions()
            + VolumeTools.toolDefinitions()
            + NetworkTools.toolDefinitions()
            + ComposeTools.toolDefinitions()
    }

    func registerHandlers(on server: Server, keyHolder: MCPKeyHolder) async {
        await server.withMethodHandler(ListTools.self) { [self] _ in
            .init(tools: allTools())
        }

        await server.withMethodHandler(CallTool.self) { [self] params in
            let start = Date()
            // Snapshot the key + params up front so the log entry is consistent
            // even if the handler takes a while.
            let keyName = keyHolder.keyName
            let paramsJSON = Self.encodeParams(params.arguments)
            do {
                let result = try await dispatch(name: params.name, arguments: params.arguments)
                let duration = Date().timeIntervalSince(start)
                // A handler that returned isError == true is a tool-level failure
                // (bad input, not-found) — record it as unsuccessful so the log
                // reflects reality, not just thrown errors.
                let toolFailed = result.isError ?? false
                await MainActor.run {
                    requestLog.record(
                        tool: params.name,
                        duration: duration,
                        success: !toolFailed,
                        error: toolFailed ? Self.firstText(result) : nil,
                        keyName: keyName,
                        params: paramsJSON)
                }
                return result
            } catch {
                let duration = Date().timeIntervalSince(start)
                // A cancellation (raw or wrapped by ContainerClient) is the client
                // aborting, not a server failure — surface it as such and don't
                // pollute the log's error stats.
                if error.isCancellation {
                    await MainActor.run {
                        requestLog.record(tool: params.name, duration: duration, success: false, error: "Cancelled", keyName: keyName, params: paramsJSON)
                    }
                    return .init(
                        content: [.text(text: "Cancelled", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                let errorMsg = error.localizedDescription
                await MainActor.run {
                    requestLog.record(tool: params.name, duration: duration, success: false, error: errorMsg, keyName: keyName, params: paramsJSON)
                }
                return .init(
                    content: [.text(text: "Error: \(errorMsg)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }
    }

    /// The first text block of a result, for logging a tool-level error message.
    private static func firstText(_ result: CallTool.Result) -> String? {
        for block in result.content {
            if case .text(let text, _, _) = block { return text }
        }
        return nil
    }

    /// Serialize a tool call's arguments to a readable YAML-like string for the
    /// request-log detail sheet. Multi-line strings (e.g. a compose yaml arg)
    /// render as `|` block scalars with real newlines; arrays use `-`; `/` is
    /// left unescaped. Nil for empty/nil args so the detail stays quiet for
    /// no-arg tools.
    private static func encodeParams(_ arguments: [String: Value]?) -> String? {
        guard let arguments, !arguments.isEmpty else { return nil }
        var lines: [String] = []
        for key in arguments.keys.sorted() {
            renderValue(arguments[key]!, key: key, indent: "", into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// Render one key/value pair (YAML-ish) into `lines`.
    private static func renderValue(_ value: Value, key: String, indent: String, into lines: inout [String]) {
        switch value {
        case .string(let s):
            if s.contains("\n") {
                lines.append("\(indent)\(key): |")
                for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("\(indent)  \(line)")
                }
            } else {
                lines.append("\(indent)\(key): \(s)")
            }
        case .int(let i): lines.append("\(indent)\(key): \(i)")
        case .double(let d): lines.append("\(indent)\(key): \(d)")
        case .bool(let b): lines.append("\(indent)\(key): \(b)")
        case .null: lines.append("\(indent)\(key): null")
        case .data(let mime, _): lines.append("\(indent)\(key): <data \(mime ?? "")>")
        case .array(let arr):
            if arr.isEmpty { lines.append("\(indent)\(key): []") }
            else {
                lines.append("\(indent)\(key):")
                for item in arr { renderItem(item, indent: indent + "  ", into: &lines) }
            }
        case .object(let obj):
            if obj.isEmpty { lines.append("\(indent)\(key): {}") }
            else {
                lines.append("\(indent)\(key):")
                for k in obj.keys.sorted() {
                    renderValue(obj[k]!, key: k, indent: indent + "  ", into: &lines)
                }
            }
        }
    }

    /// Render one array item (YAML-ish `- value`), with a block scalar for
    /// multi-line strings.
    private static func renderItem(_ value: Value, indent: String, into lines: inout [String]) {
        switch value {
        case .string(let s):
            if s.contains("\n") {
                lines.append("\(indent)- |")
                for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("\(indent)  \(line)")
                }
            } else {
                lines.append("\(indent)- \(s)")
            }
        case .int(let i): lines.append("\(indent)- \(i)")
        case .double(let d): lines.append("\(indent)- \(d)")
        case .bool(let b): lines.append("\(indent)- \(b)")
        case .null: lines.append("\(indent)- null")
        case .data(let mime, _): lines.append("\(indent)- <data \(mime ?? "")>")
        case .array(let arr):
            lines.append("\(indent)- \(arr.map { String(describing: $0) }.joined(separator: ", "))")
        case .object(let obj):
            lines.append("\(indent)-")
            for k in obj.keys.sorted() {
                renderValue(obj[k]!, key: k, indent: indent + "  ", into: &lines)
            }
        }
    }

    private func dispatch(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        switch name {
        // Containers
        case "container_list":
            return try await ContainerTools.handleList(bridge: bridge)
        case "container_create":
            return try await ContainerTools.handleCreate(arguments: arguments, bridge: bridge)
        case "container_start":
            return try await ContainerTools.handleStart(arguments: arguments, bridge: bridge)
        case "container_stop":
            return try await ContainerTools.handleStop(arguments: arguments, bridge: bridge)
        case "container_delete":
            return try await ContainerTools.handleDelete(arguments: arguments, bridge: bridge)
        case "container_exec":
            return try await ContainerTools.handleExec(arguments: arguments, bridge: bridge)
        case "container_logs":
            return try await ContainerTools.handleLogs(arguments: arguments, bridge: bridge)
        case "container_inspect":
            return try await ContainerTools.handleInspect(arguments: arguments, bridge: bridge)
        // Images
        case "image_list":
            return try await ImageTools.handleList(bridge: bridge)
        case "image_pull":
            return try await ImageTools.handlePull(arguments: arguments, bridge: bridge)
        case "image_delete":
            return try await ImageTools.handleDelete(arguments: arguments, bridge: bridge)
        // Machines
        case "machine_list":
            return try await MachineTools.handleList(bridge: bridge)
        case "machine_boot":
            return try await MachineTools.handleBoot(arguments: arguments, bridge: bridge)
        case "machine_stop":
            return try await MachineTools.handleStop(arguments: arguments, bridge: bridge)
        case "machine_delete":
            return try await MachineTools.handleDelete(arguments: arguments, bridge: bridge)
        // Volumes
        case "volume_list":
            return try await VolumeTools.handleList(bridge: bridge)
        case "volume_create":
            return try await VolumeTools.handleCreate(arguments: arguments, bridge: bridge)
        case "volume_delete":
            return try await VolumeTools.handleDelete(arguments: arguments, bridge: bridge)
        // Networks
        case "network_list":
            return try await NetworkTools.handleList(bridge: bridge)
        case "network_create":
            return try await NetworkTools.handleCreate(arguments: arguments, bridge: bridge)
        case "network_delete":
            return try await NetworkTools.handleDelete(arguments: arguments, bridge: bridge)
        // Compose
        case "compose_list":
            return try await ComposeTools.handleList(bridge: bridge)
        case "compose_up":
            return try await ComposeTools.handleUp(arguments: arguments, bridge: bridge)
        case "compose_down":
            return try await ComposeTools.handleDown(arguments: arguments, bridge: bridge)
        case "compose_status":
            return try await ComposeTools.handleStatus(arguments: arguments, bridge: bridge)
        default:
            return .init(
                content: [.text(text: "Unknown tool: \(name)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }
}
