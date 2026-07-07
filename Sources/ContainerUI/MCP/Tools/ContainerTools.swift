import ContainerAPIClient
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
            Tool(
                name: "container_exec",
                description: "Run a command in a running container; returns stdout, stderr, and the exit code. Non-zero exit is reported, not treated as a tool error.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Container ID or name")]),
                        "command": .object(["type": .string("string"), "description": .string("Executable to run, e.g. \"redis-cli\" or \"sh\"")]),
                        "args": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Arguments to pass to the command")]),
                        "user": .object(["type": .string("string"), "description": .string("Run as this user (optional)")]),
                    ]),
                    "required": .array([.string("id"), .string("command")]),
                ]),
                annotations: .init(destructiveHint: false, idempotentHint: false)
            ),
            Tool(
                name: "container_logs",
                description: "Fetch a container's stdout/stderr logs (one-shot snapshot, not followed).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Container ID or name")]),
                        "tail": .object(["type": .string("integer"), "description": .string("Number of lines to return from the end (default 200; 0 = all, subject to a 256 KB cap)")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "container_inspect",
                description: "Show detailed configuration and runtime state for a container (image, status, networks/IPs, ports, command, labels, mounts, resources).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("string"), "description": .string("Container ID or name")]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: .init(readOnlyHint: true)
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

    static func handleExec(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        guard let command = arguments?["command"]?.stringValue, !command.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: command", annotations: nil, _meta: nil)], isError: true)
        }
        let args = arguments?["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let user = arguments?["user"]?.stringValue
        let containers = await MainActor.run { bridge.containers.containers }
        guard containers.contains(where: { $0.id == id }) else {
            return .init(content: [.text(text: "Container not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        // A non-zero exit is the command's result, not a tool error — return it
        // so the caller can see stdout/stderr and judge for itself.
        let result = try await ContainerExec.runCapture(id: id, command: command, args: args, user: user)
        var text = "exit=\(result.exitCode)"
        if !result.stdout.isEmpty { text += "\n--- stdout ---\n\(result.stdout)" }
        if !result.stderr.isEmpty { text += "\n--- stderr ---\n\(result.stderr)" }
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    static func handleLogs(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        let tail = arguments?["tail"]?.intValue ?? 200
        let containers = await MainActor.run { bridge.containers.containers }
        guard containers.contains(where: { $0.id == id }) else {
            return .init(content: [.text(text: "Container not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        // Fresh client per call — cached XPC connections go stale across apiserver
        // restarts (same rationale as ContainerLogsModel / ContainersModel).
        let handles = try await ContainerClient().logs(id: id)
        let maxBytes = 256 * 1024
        var combined = ""
        if let stdout = handles.first {
            if let str = try await Self.readTail(stdout, maxBytes: maxBytes) {
                combined += str
            }
        }
        // handles[1], if present, is stderr.
        if let stderr = handles.dropFirst().first {
            if let str = try await Self.readTail(stderr, maxBytes: maxBytes), !str.isEmpty {
                combined += combined.isEmpty ? str : "\n--- stderr ---\n" + str
            }
        }
        let trimmed = Self.tailAndCap(combined, tailLines: tail, maxBytes: maxBytes)
        return .init(content: [.text(text: trimmed.isEmpty ? "(no logs)" : trimmed, annotations: nil, _meta: nil)])
    }

    /// Read at most the last `maxBytes` of a log file handle, seeking past the
    /// head instead of loading the whole file. `logs(id:)` returns handles to
    /// on-disk log files, so a multi-GB log is bounded to `maxBytes` in memory
    /// rather than read in full and trimmed afterward. Runs the blocking file
    /// I/O off the calling thread.
    private static func readTail(_ handle: FileHandle, maxBytes: Int) async throws -> String? {
        let data = try await Task.detached {
            let end = try handle.seekToEnd()
            if end > UInt64(maxBytes) {
                try handle.seek(toOffset: end - UInt64(maxBytes))
            } else {
                try handle.seek(toOffset: 0)
            }
            return try handle.readToEnd()
        }.value
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func handleInspect(arguments: [String: Value]?, bridge: MCPModelBridge) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue, !id.isEmpty else {
            return .init(content: [.text(text: "Missing required parameter: id", annotations: nil, _meta: nil)], isError: true)
        }
        let containers = await MainActor.run { bridge.containers.containers }
        guard let c = containers.first(where: { $0.id == id }) else {
            return .init(content: [.text(text: "Container not found: \(id)", annotations: nil, _meta: nil)], isError: true)
        }
        var lines: [String] = []
        lines.append("id: \(c.id)")
        lines.append("image: \(c.configuration.image.reference)")
        lines.append("status: \(c.status.rawValue)")
        if !c.networks.isEmpty {
            let nets = c.networks.map { a -> String in
                let ip = a.ipv4Address.address.description
                let host = a.hostname.isEmpty ? "" : ", \(a.hostname)"
                return "\(a.network) (\(ip)\(host))"
            }.joined(separator: ", ")
            lines.append("networks: \(nets)")
        }
        if !c.configuration.publishedPorts.isEmpty {
            let ports = c.configuration.publishedPorts
                .map { "\($0.hostPort):\($0.containerPort)" }
                .joined(separator: ", ")
            lines.append("ports: \(ports)")
        }
        let cmd = ([c.configuration.initProcess.executable] + c.configuration.initProcess.arguments)
            .joined(separator: " ")
        lines.append("command: \(cmd)")
        if !c.configuration.mounts.isEmpty {
            let mounts = c.configuration.mounts
                .map { "\($0.source)→\($0.destination)" }
                .joined(separator: ", ")
            lines.append("mounts: \(mounts)")
        }
        let res = c.configuration.resources
        let memMB = res.memoryInBytes / (1024 * 1024)
        lines.append("resources: cpus=\(res.cpus) memory=\(memMB)MB")
        if !c.configuration.labels.isEmpty {
            let labels = c.configuration.labels
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n  ")
            lines.append("labels:\n  \(labels)")
        }
        if let started = c.startedDate { lines.append("started: \(started)") }
        lines.append("created: \(c.configuration.creationDate)")
        // The snapshot carries only RuntimeStatus, not an exit code — be honest
        // about that so a caller doesn't read "stopped" as success.
        if c.status == .stopped {
            lines.append("exit code: n/a (not retained; use compose_up wait or read container_logs)")
        }
        return .init(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)])
    }

    /// Keep log responses bounded: first cap to the last `maxBytes` (logs are
    /// most useful at the tail), then take the last `tailLines` lines. A
    /// `tailLines` of 0 means "all lines" (still subject to the byte cap).
    private static func tailAndCap(_ text: String, tailLines: Int, maxBytes: Int) -> String {
        var s = text
        if s.utf8.count > maxBytes {
            let cut = s.utf8.index(s.utf8.endIndex, offsetBy: -maxBytes, limitedBy: s.utf8.startIndex) ?? s.utf8.startIndex
            s = String(s[cut...])
            // Drop the partial first line left by the byte cut.
            if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        }
        if tailLines > 0 {
            var lines = s.components(separatedBy: "\n")
            if lines.count > tailLines { lines = Array(lines.suffix(tailLines)) }
            s = lines.joined(separator: "\n")
        }
        return s
    }
}
