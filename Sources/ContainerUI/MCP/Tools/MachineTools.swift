import Foundation
import MCP

enum MachineTools {
    static func toolDefinitions() -> [Tool] {
        [
            Tool(
                name: "machine_list",
                description: "List all machines with their status and configuration",
                inputSchema: .object(["type": .string("object")]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "machine_boot",
                description: "Boot a stopped machine",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Machine ID")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: .init(destructiveHint: false, idempotentHint: true)
            ),
            Tool(
                name: "machine_stop",
                description: "Stop a running machine",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Machine ID")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: .init(destructiveHint: false, idempotentHint: true)
            ),
            Tool(
                name: "machine_delete",
                description: "Delete a machine",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Machine ID")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: .init(destructiveHint: true, idempotentHint: true)
            ),
        ]
    }

    static func handleList(bridge: MCPModelBridge) async throws -> CallTool.Result {
        let machines = await MainActor.run { bridge.machines.machines }
        let items = machines.map { m -> String in
            let ip = m.ipAddress ?? "no IP"
            return "[\(m.status)] \(m.id) — \(ip)"
        }.joined(separator: "\n")
        return .init(content: [.text(text: items.isEmpty ? "No machines found" : items, annotations: nil, _meta: nil)])
    }

    static func handleBoot(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        let machines = await MainActor.run { bridge.machines.machines }
        guard let machine = machines.first(where: { $0.id == id }) else {
            return .init(content: [.text(text: "Machine not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        try await bridge.machines.bootThrowing(machine)
        return .init(content: [.text(text: "Machine \(machine.id) booted", annotations: nil, _meta: nil)])
    }

    static func handleStop(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        let machines = await MainActor.run { bridge.machines.machines }
        guard let machine = machines.first(where: { $0.id == id }) else {
            return .init(content: [.text(text: "Machine not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        try await bridge.machines.stopThrowing(machine)
        return .init(content: [.text(text: "Machine \(machine.id) stopped", annotations: nil, _meta: nil)])
    }

    static func handleDelete(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        let machines = await MainActor.run { bridge.machines.machines }
        guard let machine = machines.first(where: { $0.id == id }) else {
            return .init(content: [.text(text: "Machine not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        try await bridge.machines.deleteThrowing(machine)
        return .init(content: [.text(text: "Machine \(machine.id) deleted", annotations: nil, _meta: nil)])
    }
}
