import Foundation
import MCP

enum ComposeTools {
    static func toolDefinitions() -> [Tool] {
        [
            Tool(
                name: "compose_list",
                description: "List all Compose projects with their services and status",
                inputSchema: .object(["type": .string("object")]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "compose_up",
                description: "Create and start a Compose project from YAML content",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "yaml": .object(["type": .string("string"), "description": .string("Compose YAML content")]),
                        "projectName": .object(["type": .string("string"), "description": .string("Project name (optional)")]),
                    ]),
                    "required": .array([.string("yaml")]),
                ]),
                annotations: .init(destructiveHint: false, idempotentHint: false)
            ),
            Tool(
                name: "compose_down",
                description: "Stop and remove all containers in a Compose project",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "projectName": .object(["type": .string("string"), "description": .string("Project name to bring down")]),
                        "removeVolumes": .object(["type": .string("boolean"), "description": .string("Also remove volumes")]),
                        "removeNetworks": .object(["type": .string("boolean"), "description": .string("Also remove networks")]),
                    ]),
                    "required": .array([.string("projectName")]),
                ]),
                annotations: .init(destructiveHint: true, idempotentHint: true)
            ),
            Tool(
                name: "compose_status",
                description: "Get the status of a Compose project's services",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "projectName": .object(["type": .string("string"), "description": .string("Project name")]),
                    ]),
                    "required": .array([.string("projectName")]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
        ]
    }

    static func handleList(bridge: MCPModelBridge) async throws -> CallTool.Result {
        let projects = await MainActor.run { bridge.compose.projects }
        let items = projects.map { p -> String in
            let status = p.isDown ? "down" : "\(p.runningCount)/\(p.totalCount) running"
            return "\(p.name) — \(status) (stored: \(p.isStored))"
        }.joined(separator: "\n")
        return .init(content: [.text(text: items.isEmpty ? "No compose projects found" : items, annotations: nil, _meta: nil)])
    }

    static func handleUp(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let yaml = arguments?["yaml"]?.stringValue, !yaml.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: yaml", annotations: nil, _meta: nil)], isError: true)
        }
        let projectName = arguments?["projectName"]?.stringValue ?? "mcp-project"

        let record = ComposeProjectRecord(
            name: projectName,
            yaml: yaml,
            declaredNetworks: [],
            declaredVolumes: [],
            importedAt: Date()
        )
        await MainActor.run {
            bridge.compose.startUp(record: record)
        }
        return .init(content: [.text(text: "Compose up started for project: \(projectName)", annotations: nil, _meta: nil)])
    }

    static func handleDown(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let projectName = arguments?["projectName"]?.stringValue, !projectName.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: projectName", annotations: nil, _meta: nil)], isError: true)
        }
        let removeVolumes = arguments?["removeVolumes"]?.boolValue ?? false
        let removeNetworks = arguments?["removeNetworks"]?.boolValue ?? false
        await bridge.compose.down(project: projectName, removeVolumes: removeVolumes, removeNetworks: removeNetworks)
        return .init(content: [.text(text: "Compose project '\(projectName)' brought down", annotations: nil, _meta: nil)])
    }

    static func handleStatus(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let projectName = arguments?["projectName"]?.stringValue, !projectName.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: projectName", annotations: nil, _meta: nil)], isError: true)
        }
        let projects = await MainActor.run { bridge.compose.projects }
        guard let project = projects.first(where: { $0.name == projectName }) else {
            return .init(content: [.text(text: "Project not found: \(projectName)", annotations: nil, _meta: nil)], isError: true)
        }
        let services = project.services.map { s -> String in
            "\(s.service): \(s.status.map { "\($0)" } ?? "unknown")"
        }.joined(separator: "\n")
        let summary = "Project: \(project.name)\nRunning: \(project.runningCount)/\(project.totalCount)\n\n\(services)"
        return .init(content: [.text(text: summary, annotations: nil, _meta: nil)])
    }
}
