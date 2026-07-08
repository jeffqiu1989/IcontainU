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

    /// Run `container exec [-u user] <id> <command> [args]` to completion and
    /// capture stdout, stderr, and the exit code. Unlike `run`, a non-zero exit
    /// is **not** an error — the code is returned so callers (the MCP
    /// `container_exec` tool) can report success/failure themselves. Throws only
    /// on a missing binary or a launch failure.
    ///
    /// stdout and stderr are drained concurrently with `waitUntilExit` so a
    /// command that emits more than the pipe buffer (~64 KB) on either stream
    /// can't deadlock the process while we wait for it to exit.
    static func runCapture(
        id: String, command: String, args: [String],
        user: String? = nil
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        guard let bin = binaryPath else { throw Error.containerNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        var argv = ["exec"]
        if let user { argv += ["-u", user] }
        argv += [id, command] + args
        process.arguments = argv
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        // Drain both pipes off the calling thread so a large output can't fill
        // the pipe buffer and block the process before `waitUntilExit` returns.
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        let outTask = Task.detached { try outHandle.readToEnd() }
        let errTask = Task.detached { try errHandle.readToEnd() }
        process.waitUntilExit()
        let outData = (try? await outTask.value) ?? Data()
        let errData = (try? await errTask.value) ?? Data()
        return (
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Run a health-check probe via `container exec` and report whether it
    /// succeeded. Unlike `run`, this:
    ///   - returns `Bool` instead of throwing on non-zero exit (a non-zero exit
    ///     is the normal "unhealthy" signal, not an error);
    ///   - enforces a `timeout` by racing the process against a sleep and
    ///     killing it on overrun, so a hung probe never stalls the Up loop;
    ///   - cooperates with cancellation — a cancelled probe kills the process.
    ///
    /// A missing binary is the only hard failure (thrown); a process that fails
    /// to launch is reported as unhealthy (`false`) rather than thrown, so one
    /// bad probe degrades the service to "unhealthy" instead of aborting the
    /// project. `Process` is `Sendable` on this SDK, so capturing it in the task
    /// group's child tasks (and the cancellation handler) is sound.
    static func runProbe(
        id: String, command: String, args: [String],
        user: String? = nil, timeout: TimeInterval
    ) async throws -> Bool {
        guard let bin = binaryPath else { throw Error.containerNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        var argv = ["exec"]
        if let user { argv += ["-u", user] }
        argv += [id, command] + args
        process.arguments = argv
        // The probe is judged solely by exit code; discard its output.
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return false }

        return await withTaskCancellationHandler {
            await withTaskGroup(of: ProbeOutcome.self) { group in
                group.addTask {
                    process.waitUntilExit()
                    return .exited(status: process.terminationStatus)
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeout))
                    return .timedOut
                }
                let first = await group.next() ?? .timedOut
                group.cancelAll()
                // If the timeout (or cancel) won and the process is still
                // alive, kill it — `waitUntilExit()` is a blocking C call that
                // cancellation alone can't interrupt, so terminate() is what
                // lets the exit task complete and the group close.
                if process.isRunning { process.terminate() }
                // Drain the remaining task so the group returns cleanly.
                while await group.next() != nil {}
                switch first {
                case .exited(let status): return status == 0
                case .timedOut: return false
                }
            }
        } onCancel: {
            // Cooperate with parent cancellation: kill the probe so its exit
            // task resumes promptly instead of blocking on `waitUntilExit()`.
            process.terminate()
        }
    }

    private enum ProbeOutcome {
        case exited(status: Int32)
        case timedOut
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
