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
                description: "Create and start a Compose project from YAML content. Set wait>0 to block until one-shot/init services exit and report their exit codes (a non-zero exit makes the call an error).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "yaml": .object(["type": .string("string"), "description": .string("Compose YAML content")]),
                        "projectName": .object(["type": .string("string"), "description": .string("Project name (optional)")]),
                        "wait": .object(["type": .string("integer"), "description": .string("Seconds to wait for services to exit. 0 (default) returns as soon as containers start. A one-shot/init service that exits within the window reports its exit code; a long-running server reports as running.")]),
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
        let wait = arguments?["wait"]?.intValue ?? 0

        // MCP never allows host-path bind mounts (named volumes only): an agent
        // driving the server shouldn't touch arbitrary host files. Use the app
        // UI to bring up a project with a host bind mount.
        let binds = Self.hostBindMounts(in: yaml)
        if !binds.isEmpty {
            let list = binds.joined(separator: ", ")
            return .init(content: [.text(text: "Host-path bind mounts are not supported over MCP (named volumes only). Use the app's UI to mount a host directory. Found: \(list)", annotations: nil, _meta: nil)], isError: true)
        }

        // declaredNetworks/Volumes are left empty here — upAndWait re-parses the
        // YAML and fills them so a later compose_down can reclaim the resources.
        let record = ComposeProjectRecord(
            name: projectName,
            yaml: yaml,
            declaredNetworks: [],
            declaredVolumes: [],
            importedAt: Date()
        )
        let outcomes = try await bridge.compose.upAndWait(record: record, waitSeconds: wait)

        // Without a wait window, keep the original terse confirmation.
        guard wait > 0, !outcomes.isEmpty else {
            return .init(content: [.text(text: "Compose project '\(projectName)' is up", annotations: nil, _meta: nil)])
        }

        // Report each service's outcome. A one-shot/init service that exited
        // non-zero is a failure — surface it as an error so the caller doesn't
        // read "is up" as success when init actually failed.
        let lines = outcomes
            .sorted { $0.service < $1.service }
            .map { o -> String in
                if o.exited {
                    return "\(o.service): exited (code \(o.exitCode ?? -1))"
                } else {
                    return "\(o.service): running"
                }
            }
        let failed = outcomes.filter { $0.exited && ($0.exitCode ?? 0) != 0 }
        let header = failed.isEmpty
            ? "Compose project '\(projectName)' is up"
            : "Compose project '\(projectName)' up with \(failed.count) failed service(s)"
        let text = header + "\n" + lines.joined(separator: "\n")
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: !failed.isEmpty)
    }

    static func handleDown(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let projectName = arguments?["projectName"]?.stringValue, !projectName.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: projectName", annotations: nil, _meta: nil)], isError: true)
        }
        let removeVolumes = arguments?["removeVolumes"]?.boolValue ?? false
        let removeNetworks = arguments?["removeNetworks"]?.boolValue ?? false
        try await bridge.compose.downThrowing(project: projectName, removeVolumes: removeVolumes, removeNetworks: removeNetworks)
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
            switch s.status {
            case .stopped:
                // A stopped container's exit code is known only when a
                // capturing Up (`wait`) recorded it — otherwise the framework
                // retains none.
                if let code = s.exitCode {
                    return "\(s.service): stopped (exit \(code))"
                }
                return "\(s.service): stopped (exit unknown)"
            case .some(let other):
                return "\(s.service): \(other)"
            case nil:
                return "\(s.service): unknown"
            }
        }.joined(separator: "\n")
        let summary = "Project: \(project.name)\nRunning: \(project.runningCount)/\(project.totalCount)\n\n\(services)"
        return .init(content: [.text(text: summary, annotations: nil, _meta: nil)])
    }

    /// Return the short-syntax host-path bind mounts in the YAML (sources that
    /// contain "/" or start with "~"). Anonymous volumes (`/data`, no colon) and
    /// named volumes are skipped. Long-syntax volumes are already dropped by the
    /// parser, so only short syntax is checked. Best-effort: if interpolation or
    /// parsing fails, returns empty (the up path will surface the real error).
    private static func hostBindMounts(in yaml: String) -> [String] {
        guard let interpolated = try? EnvInterpolator.interpolate(yaml: yaml, baseDirectory: nil),
              let file = try? ComposeParser.parse(yaml: interpolated.text) else { return [] }
        var found: [String] = []
        for service in file.services.values {
            for vol in service.volumes {
                guard vol.contains(":") else { continue }
                let source = vol.split(separator: ":", maxSplits: 1).first.map(String.init) ?? vol
                if source.contains("/") || source.hasPrefix("~") {
                    found.append(vol)
                }
            }
        }
        return found
    }
}
