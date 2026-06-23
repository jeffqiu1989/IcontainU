import Foundation

/// Opens an interactive command in the macOS Terminal app. Used for `exec` into a
/// container and `machine run`, which need a real TTY that the GUI does not host
/// itself. Terminal.app is driven via AppleScript (`do script`).
enum TerminalLauncher {
    /// Well-known install locations for the `container` CLI, checked in order
    /// before falling back to a PATH lookup.
    private static let candidatePaths = [
        "/usr/local/bin/container",    // apple/container installer default
        "/opt/homebrew/bin/container",  // Homebrew on Apple silicon
    ]

    /// The resolved absolute path to the `container` CLI, or nil if not installed.
    static var resolvedContainerBinary: String? {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return lookupOnPath("container")
    }

    enum LaunchError: LocalizedError {
        case scriptFailed(String)
        case containerNotFound

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message): "Failed to open Terminal: \(message)"
            case .containerNotFound:
                "Couldn't find the `container` CLI. Install Apple container "
                    + "(https://github.com/apple/container), or make sure it's in "
                    + "/usr/local/bin, /opt/homebrew/bin, or your PATH."
            }
        }
    }

    /// The resolved `container` path, or a clear error if it isn't installed.
    private static func binaryPath() throws -> String {
        guard let path = resolvedContainerBinary else { throw LaunchError.containerNotFound }
        return path
    }

    /// Open a shell inside a running container: `container exec -it <id> <shell>`.
    static func execInContainer(id: String, shell: String = "/bin/sh") throws {
        let bin = try binaryPath()
        try run([bin, "exec", "-it", id, shell])
    }

    /// Open a login shell in a container machine: `container machine run -n <id>`.
    static func runInMachine(id: String) throws {
        let bin = try binaryPath()
        try run([bin, "machine", "run", "-n", id])
    }

    /// Whether the `container` CLI is installed (resolved from known paths / PATH).
    static var isContainerInstalled: Bool {
        resolvedContainerBinary != nil
    }

    /// Whether a default kernel is already provisioned. Checks the well-known
    /// symlink under the container app-support directory so the GUI can decide
    /// whether the first start will trigger a kernel download.
    static var isKernelInstalled: Bool {
        let appRoot = ProcessInfo.processInfo.environment["CONTAINER_APP_ROOT"]
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("com.apple.container").path
            ?? NSHomeDirectory() + "/Library/Application Support/com.apple.container"
        let arch = "arm64"
        let kernelPath = (appRoot as NSString).appendingPathComponent("kernels/default.kernel-\(arch)")
        return FileManager.default.fileExists(atPath: kernelPath)
    }

    /// Start the container system silently (no Terminal). Kernel install is
    /// enabled so that first-time setups automatically download the kernel.
    /// On subsequent starts the upstream CLI skips the download if a kernel
    /// already exists. Throws with stderr on failure.
    static func startSystem() throws {
        let bin = try binaryPath()
        try runSilently([bin, "system", "start", "--enable-kernel-install"])
    }

    /// Stop the container system silently (no Terminal).
    static func stopSystem() throws {
        let bin = try binaryPath()
        try runSilently([bin, "system", "stop"])
    }

    /// Quote each argument for the shell, join into a command line, then run it in
    /// a new Terminal window via AppleScript.
    private static func run(_ arguments: [String]) throws {
        let commandLine = arguments.map(shellQuote).joined(separator: " ")
        let script =
            "tell application \"Terminal\"\n"
            + "activate\n"
            + "do script \"\(appleScriptQuote(commandLine))\"\n"
            + "end tell"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LaunchError.scriptFailed(error.localizedDescription)
        }

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw LaunchError.scriptFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Single-quote a shell argument, escaping any embedded single quotes.
    private static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run a command directly (no Terminal), waiting for it to finish. Throws with
    /// captured stderr on a non-zero exit.
    private static func runSilently(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LaunchError.scriptFailed(error.localizedDescription)
        }

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw LaunchError.scriptFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Escape a string for embedding inside an AppleScript double-quoted literal.
    private static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Best-effort PATH lookup via `/usr/bin/which`. GUI apps inherit a minimal
    /// PATH, so this mainly catches non-standard installs; `candidatePaths` covers
    /// the common cases. Returns nil if the tool isn't found or isn't executable.
    private static func lookupOnPath(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty,
            FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }
}
