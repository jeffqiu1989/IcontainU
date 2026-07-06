import Foundation
import MCP

enum ImageTools {
    static func toolDefinitions() -> [Tool] {
        [
            Tool(
                name: "image_list",
                description: "List all container images with their references and sizes",
                inputSchema: .object(["type": .string("object")]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "image_pull",
                description: "Pull a container image from a registry",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "reference": .object(["type": .string("string"), "description": .string("Image reference, e.g. nginx:latest or ubuntu:22.04")]),
                    ]),
                    "required": .array([.string("reference")]),
                ]),
                annotations: .init(destructiveHint: false, idempotentHint: true)
            ),
            Tool(
                name: "image_delete",
                description: "Delete a container image",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Image ID or reference")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: .init(destructiveHint: true, idempotentHint: true)
            ),
        ]
    }

    static func handleList(bridge: MCPModelBridge) async throws -> CallTool.Result {
        let images = await MainActor.run { bridge.images.images }
        let items = images.map { img -> String in
            img.displayReference
        }.joined(separator: "\n")
        return .init(content: [.text(text: items.isEmpty ? "No images found" : items, annotations: nil, _meta: nil)])
    }

    static func handlePull(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let reference = arguments?["reference"]?.stringValue, !reference.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: reference", annotations: nil, _meta: nil)], isError: true)
        }
        let resolved = try await bridge.images.pullAndWait(reference: reference)
        return .init(content: [.text(text: "Image pulled: \(resolved)", annotations: nil, _meta: nil)])
    }

    static func handleDelete(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        let images = await MainActor.run { bridge.images.images }
        guard let image = images.first(where: { $0.id == id || $0.displayReference == id }) else {
            return .init(content: [.text(text: "Image not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        try await bridge.images.deleteThrowing(image)
        return .init(content: [.text(text: "Image deleted: \(image.displayReference)", annotations: nil, _meta: nil)])
    }
}
