import Foundation
import MCP

enum NetworkTools {
    static func toolDefinitions() -> [Tool] {
        [
            Tool(
                name: "network_list",
                description: "List all networks with their IDs, names, and modes",
                inputSchema: .object(["type": .string("object")]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "network_create",
                description: "Create a new network",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Network name")]),
                        "hostOnly": .object(["type": .string("boolean"), "description": .string("Host-only network (no NAT)")]),
                        "subnet": .object(["type": .string("string"), "description": .string("IPv4 subnet in CIDR notation, e.g. '10.0.1.0/24'. Blank for auto")]),
                    ]),
                    "required": .array([.string("name")]),
                ]),
                annotations: .init(destructiveHint: false, idempotentHint: false)
            ),
            Tool(
                name: "network_delete",
                description: "Delete a network",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Network ID to delete")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: .init(destructiveHint: true, idempotentHint: true)
            ),
        ]
    }

    static func handleList(bridge: MCPModelBridge) async throws -> CallTool.Result {
        let networks = await MainActor.run { bridge.networks.networks }
        let items = networks.map { n -> String in
            "\(n.id) — \(n.configuration.name) (\(n.configuration.mode))"
        }.joined(separator: "\n")
        return .init(content: [.text(text: items.isEmpty ? "No networks found" : items, annotations: nil, _meta: nil)])
    }

    static func handleCreate(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let name = arguments?["name"]?.stringValue, !name.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: name", annotations: nil, _meta: nil)], isError: true)
        }
        let hostOnly = arguments?["hostOnly"]?.boolValue ?? false
        let subnet = arguments?["subnet"]?.stringValue ?? ""
        await bridge.networks.create(name: name, hostOnly: hostOnly, subnet: subnet)
        return .init(content: [.text(text: "Network created: \(name)", annotations: nil, _meta: nil)])
    }

    static func handleDelete(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        let networks = await MainActor.run { bridge.networks.networks }
        guard let network = networks.first(where: { $0.id == id }) else {
            return .init(content: [.text(text: "Network not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        await bridge.networks.delete(network)
        return .init(content: [.text(text: "Network deleted: \(id)", annotations: nil, _meta: nil)])
    }
}
