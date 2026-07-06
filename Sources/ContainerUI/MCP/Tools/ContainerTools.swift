import Foundation
import MCP

enum ContainerTools {
    static func toolDefinitions() -> [Tool] {
        [
            Tool(
                name: "container_list",
                description: "List all containers with their status, image, and network info",
                inputSchema: .object(["type": .string("object")]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "container_create",
                description: "Create and start a new container from an image",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "image": .object(["type": .string("string"), "description": .string("Image reference, e.g. nginx:latest")]),
                        "name": .object(["type": .string("string"), "description": .string("Container name (optional, auto-generated if empty)")]),
                        "command": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Command arguments")]),
                        "ports": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Port mappings, e.g. '8080:80'")]),
                        "volumes": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Volume mounts, e.g. '/host:/data'")]),
                        "env": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Environment variables, e.g. 'KEY=VALUE'")]),
                        "networks": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Network names to attach")]),
                    ]),
                    "required": .array([.string("image")]),
                ]),
                annotations: .init(destructiveHint: false, idempotentHint: false)
            ),
            Tool(
                name: "container_start",
                description: "Start an existing stopped container",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Container ID or name")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: .init(destructiveHint: false, idempotentHint: true)
            ),
            Tool(
                name: "container_stop",
                description: "Stop a running container",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Container ID or name")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: .init(destructiveHint: false, idempotentHint: true)
            ),
            Tool(
                name: "container_delete",
                description: "Delete a container. Use force=true to delete a running container",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Container ID or name")]),
                        "force": .object(["type": .string("boolean"), "description": .string("Force delete even if running")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: .init(destructiveHint: true, idempotentHint: true)
            ),
        ]
    }

    static func handleList(bridge: MCPModelBridge) async throws -> CallTool.Result {
        let containers = await MainActor.run { bridge.containers.containers }
        let items = containers.map { c -> String in
            "[\(c.status)] \(c.id) — \(c.configuration.image.reference) (networks: \(c.networks.map(\.network).joined(separator: ", ")))"
        }.joined(separator: "\n")
        return .init(content: [.text(text: items.isEmpty ? "No containers found" : items, annotations: nil, _meta: nil)])
    }

    static func handleCreate(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let image = arguments?["image"]?.stringValue, !image.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: image", annotations: nil, _meta: nil)], isError: true)
        }
        let spec = ContainerCreateSpec(
            image: image,
            name: arguments?["name"]?.stringValue,
            command: arguments?["command"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            publishPorts: arguments?["ports"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            volumes: arguments?["volumes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            env: arguments?["env"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            networks: arguments?["networks"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        let id = try await bridge.containers.createAndWait(spec: spec)
        return .init(content: [.text(text: "Container created: \(id)", annotations: nil, _meta: nil)])
    }

    static func handleStart(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        let containers = await MainActor.run { bridge.containers.containers }
        guard let container = containers.first(where: { $0.id == id }) else {
            return .init(content: [.text(text: "Container not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        try await bridge.containers.startThrowing(container)
        return .init(content: [.text(text: "Container \(container.id) started", annotations: nil, _meta: nil)])
    }

    static func handleStop(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        let containers = await MainActor.run { bridge.containers.containers }
        guard let container = containers.first(where: { $0.id == id }) else {
            return .init(content: [.text(text: "Container not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        try await bridge.containers.stopThrowing(container)
        return .init(content: [.text(text: "Container \(container.id) stopped", annotations: nil, _meta: nil)])
    }

    static func handleDelete(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        let force = arguments?["force"]?.boolValue ?? false
        let containers = await MainActor.run { bridge.containers.containers }
        guard let container = containers.first(where: { $0.id == id }) else {
            return .init(content: [.text(text: "Container not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        try await bridge.containers.deleteThrowing(container, force: force)
        return .init(content: [.text(text: "Container \(container.id) deleted", annotations: nil, _meta: nil)])
    }
}
