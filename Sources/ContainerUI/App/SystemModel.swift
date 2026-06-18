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

import AppKit
import ContainerAPIClient
import Foundation
import Observation

/// Tracks whether the API server is reachable. This is the global precondition
/// for both tabs: if the apiserver is not up, nothing else can work.
@Observable
@MainActor
final class SystemModel {
    enum State: Equatable {
        case unknown
        case notInstalled
        case running(version: String)
        case unavailable
    }

    private(set) var state: State = .unknown
    private(set) var isBusy = false
    private(set) var statusHint: String?
    private(set) var actionError: String?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var versionDescription: String? {
        if case .running(let version) = state { return version }
        return nil
    }

    /// Polls the apiserver health endpoint until the task is cancelled.
    func startMonitoring() async {
        while !Task.isCancelled {
            await ping()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func ping() async {
        // An in-flight start/stop transient should not be clobbered by polling.
        guard !isBusy else { return }
        guard TerminalLauncher.isContainerInstalled else {
            state = .notInstalled
            return
        }
        do {
            let health = try await ClientHealthCheck.ping()
            state = .running(version: health.apiServerVersion)
        } catch {
            state = .unavailable
        }
    }

    /// Start the system silently. The kernel is installed automatically on
    /// first run; subsequent starts skip the download when a kernel already
    /// exists. On failure, surface the error details.
    func startSystem() async {
        isBusy = true
        actionError = nil
        statusHint = TerminalLauncher.isKernelInstalled ? nil : "Downloading kernel…"
        defer { isBusy = false; statusHint = nil }
        do {
            try await Task.detached { try TerminalLauncher.startSystem() }.value
        } catch {
            actionError =
                "Failed to start the system.\n\(error.localizedDescription)"
        }
        await ping()
    }

    func stopSystem() async {
        isBusy = true
        actionError = nil
        statusHint = nil
        defer { isBusy = false; statusHint = nil }
        do {
            try await Task.detached { try TerminalLauncher.stopSystem() }.value
        } catch {
            actionError = error.localizedDescription
        }
        await ping()
    }

    /// Open the container project's releases page to guide installation.
    func openInstallPage() {
        if let url = URL(string: "https://github.com/apple/container/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}
