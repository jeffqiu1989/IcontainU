import Foundation

/// Runs a non-interactive command inside a running container via the `container`
/// CLI's `exec` (no `-t`, no TTY). Used by features that need to touch a
/// container's filesystem without opening a Terminal window (e.g. rewriting
/// `/etc/hosts` for service discovery).
///
/// Mirrors the CLI-path resolution in `TerminalLauncher` so a restarted apiserver
/// and a non-PATH GUI environment still find `container`.
enum ContainerExec {
    private static let candidatePaths = [
        "/usr/local/bin/container",
        "/opt/homebrew/bin/container",
    ]

    enum Error: Swift.Error, LocalizedError {
        case containerNotFound
        case nonZeroExit(String)

        var errorDescription: String? {
            switch self {
            case .containerNotFound: return "Couldn't find the `container` CLI."
            case .nonZeroExit(let stderr): return "container exec failed: \(stderr)"
            }
        }
    }

    private static var binaryPath: String? {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return lookupOnPath("container")
    }

    /// Run `container exec [-u user] <id> <command> [args]` to completion. Throws
    /// on a missing binary or a non-zero exit (with captured stderr).
    static func run(id: String, command: String, args: [String], user: String? = nil) async throws {
        guard let bin = binaryPath else { throw Error.containerNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        var argv = ["exec"]
        if let user { argv += ["-u", user] }
        argv += [id, command] + args
        process.arguments = argv
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            throw Error.nonZeroExit(String(data: data, encoding: .utf8) ?? "unknown")
        }
    }

    private static func lookupOnPath(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty,
            FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }
}
