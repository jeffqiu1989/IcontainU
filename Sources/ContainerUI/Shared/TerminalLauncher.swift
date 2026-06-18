//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation

/// Opens an interactive command in the macOS Terminal app. Used for `exec` into a
/// container and `machine run`, which need a real TTY that the GUI does not host
/// itself. Terminal.app is driven via AppleScript (`do script`).
enum TerminalLauncher {
    /// Path to the installed `container` CLI.
    static let containerBinary = "/usr/local/bin/container"

    enum LaunchError: LocalizedError {
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message): "Failed to open Terminal: \(message)"
            }
        }
    }

    /// Open a shell inside a running container: `container exec -it <id> <shell>`.
    static func execInContainer(id: String, shell: String = "/bin/sh") throws {
        try run([containerBinary, "exec", "-it", id, shell])
    }

    /// Open a login shell in a container machine: `container machine run -n <id>`.
    static func runInMachine(id: String) throws {
        try run([containerBinary, "machine", "run", "-n", id])
    }

    /// Whether the `container` CLI is installed at the expected path.
    static var isContainerInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: containerBinary)
    }

    /// Whether a default kernel is already provisioned. Checks the well-known
    /// symlink under the container app-support directory so the GUI can decide
    /// whether the first start will trigger a kernel download.
    static var isKernelInstalled: Bool {
        let appRoot = ProcessInfo.processInfo.environment["CONTAINER_APP_ROOT"]
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("com.apple.container").path
        let arch = "arm64"
        let kernelPath = (appRoot as NSString).appendingPathComponent("kernels/default.kernel-\(arch)")
        return FileManager.default.fileExists(atPath: kernelPath)
    }

    /// Start the container system silently (no Terminal). Kernel install is
    /// enabled so that first-time setups automatically download the kernel.
    /// On subsequent starts the upstream CLI skips the download if a kernel
    /// already exists. Throws with stderr on failure.
    static func startSystem() throws {
        try runSilently([containerBinary, "system", "start", "--enable-kernel-install"])
    }

    /// Stop the container system silently (no Terminal).
    static func stopSystem() throws {
        try runSilently([containerBinary, "system", "stop"])
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
}
