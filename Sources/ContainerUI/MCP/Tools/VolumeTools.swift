import Foundation
import MCP

enum VolumeTools {
    static func toolDefinitions() -> [Tool] {
        [
            Tool(
                name: "volume_list",
                description: "List all volumes with their names and sizes",
                inputSchema: .object(["type": .string("object")]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "volume_create",
                description: "Create a new volume",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Volume name")]),
                        "size": .object(["type": .string("string"), "description": .string("Volume size, e.g. '10G'. Blank uses server default")]),
                    ]),
                    "required": .array([.string("name")]),
                ]),
                annotations: .init(destructiveHint: false, idempotentHint: false)
            ),
            Tool(
                name: "volume_delete",
                description: "Delete a volume",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Volume name to delete")]),
                    ]),
                    "required": .array([.string("name")]),
                ]),
                annotations: .init(destructiveHint: true, idempotentHint: true)
            ),
        ]
    }

    static func handleList(bridge: MCPModelBridge) async throws -> CallTool.Result {
        await bridge.volumes.refresh()
        let volumes = await MainActor.run { bridge.volumes.volumes }
        let items = volumes.map { v -> String in
            "\(v.name)"
        }.joined(separator: "\n")
        return .init(content: [.text(text: items.isEmpty ? "No volumes found" : items, annotations: nil, _meta: nil)])
    }

    static func handleCreate(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let name = arguments?["name"]?.stringValue, !name.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: name", annotations: nil, _meta: nil)], isError: true)
        }
        let size = arguments?["size"]?.stringValue ?? ""
        try await bridge.volumes.createThrowing(name: name, size: size)
        return .init(content: [.text(text: "Volume created: \(name)", annotations: nil, _meta: nil)])
    }

    static func handleDelete(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let name = arguments?["name"]?.stringValue, !name.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: name", annotations: nil, _meta: nil)], isError: true)
        }
        await bridge.volumes.refresh()
        let volumes = await MainActor.run { bridge.volumes.volumes }
        guard let volume = volumes.first(where: { $0.name == name }) else {
            return .init(content: [.text(text: "Volume not found: \(name)", annotations: nil, _meta: nil)], isError: true)
        }
        try await bridge.volumes.deleteThrowing(volume)
        return .init(content: [.text(text: "Volume deleted: \(name)", annotations: nil, _meta: nil)])
    }
}
