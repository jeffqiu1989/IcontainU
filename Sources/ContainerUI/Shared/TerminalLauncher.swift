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

    /// Kernel install strategy for `system start`.
    enum KernelInstallMode {
        /// `--enable-kernel-install`: let the CLI download the kernel from GitHub.
        case auto
        /// `--disable-kernel-install`: bring up apiserver without a kernel, so the
        /// GUI can install it afterwards via a mirror (with progress).
        case skip
        /// No flag: kernel is already present, just start.
        case none
    }

    /// Start the container system silently (no Terminal). The kernel install
    /// strategy controls whether the CLI downloads the default kernel itself,
    /// skips it (so the GUI installs via a mirror), or assumes it's present.
    /// Throws with stderr on failure. When a proxy is configured
    /// (`ProxyConfig.isActive`), its env vars are injected so the apiserver
    /// routes kernel downloads and image pulls through it.
    static func startSystem(kernelInstall: KernelInstallMode = .none) throws {
        let bin = try binaryPath()
        var args = [bin, "system", "start"]
        switch kernelInstall {
        case .auto: args.append("--enable-kernel-install")
        case .skip: args.append("--disable-kernel-install")
        case .none: break
        }
        try runSilently(args, environment: proxyEnvironment())
    }

    /// Stop the container system silently (no Terminal).
    static func stopSystem() throws {
        let bin = try binaryPath()
        try runSilently([bin, "system", "stop"])
    }

    /// Build the environment for `container system start`, adding proxy env vars
    /// when `ProxyConfig.isActive`. The apiserver reads `http_proxy`/`https_proxy`
    /// via `ProxyUtils.proxyFromEnvironment`; the framework allowlists these keys
    /// (`PluginLoader.proxyKeys`) so they flow from this process to the apiserver.
    /// Returns nil (inherit current env) when no proxy is configured.
    private static func proxyEnvironment() -> [String: String]? {
        let config = ProxyConfig.current
        guard let url = config.httpURLString else {
            // Record "no proxy in effect" so the UI knows the running system has
            // no proxy and can flag a later enable as needing restart.
            ProxyConfig.appliedURLString = ""
            return nil
        }
        // Remember what we're starting with, so SystemView can tell whether a
        // later edit diverges and needs a restart.
        ProxyConfig.appliedURLString = url
        var env = ProcessInfo.processInfo.environment
        env["http_proxy"] = url
        env["https_proxy"] = url
        env["HTTP_PROXY"] = url
        env["HTTPS_PROXY"] = url
        env["no_proxy"] = "localhost,127.0.0.1"
        env["NO_PROXY"] = "localhost,127.0.0.1"
        return env
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
    /// captured stderr on a non-zero exit. If `environment` is supplied it
    /// replaces the inherited environment (used to inject proxy env vars into
    /// `container system start`); otherwise the process inherits this app's env.
    private static func runSilently(_ arguments: [String], environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        if let environment {
            process.environment = environment
        }

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
