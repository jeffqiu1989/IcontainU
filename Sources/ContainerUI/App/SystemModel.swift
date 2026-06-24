import AppKit
import ContainerAPIClient
import ContainerPersistence
import Containerization
import Foundation
import Observation
import TerminalProgress

/// Tracks whether the API server is reachable. This is the global precondition
/// for both tabs: if the apiserver is not up, nothing else can work.
@Observable
@MainActor
final class SystemModel {
    enum State: Equatable {
        case unknown
        case notInstalled
        case running(version: String)
        /// Apiserver is reachable but no kernel is installed yet.
        case readyButNoKernel(version: String)
        case unavailable
    }

    private(set) var state: State = .unknown
    private(set) var isBusy = false
    private(set) var statusHint: String?
    private(set) var actionError: OperationError?
    /// Live progress for a mirror kernel download (nil when not downloading).
    private(set) var kernelProgress: OperationProgress?
    /// A blocking kernel failure: shown as an alert with Cancel / Retry.
    private(set) var kernelError: (title: String, message: String)?
    private var kernelTask: Task<Void, Never>?

    func clearKernelError() { kernelError = nil }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// The apiserver is reachable, even if no kernel is installed yet.
    var isApiserverUp: Bool {
        switch state {
        case .running, .readyButNoKernel: return true
        default: return false
        }
    }

    var versionDescription: String? {
        switch state {
        case .running(let v), .readyButNoKernel(let v): return v
        default: return nil
        }
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
        await refreshState()
    }

    /// Probe the apiserver and update `state`, regardless of `isBusy`. Used both by
    /// `ping` (background poll) and by the start flow, which needs an accurate
    /// `state` mid-operation while `isBusy` is still true.
    private func refreshState() async {
        guard TerminalLauncher.isContainerInstalled else {
            state = .notInstalled
            return
        }
        do {
            let health = try await ClientHealthCheck.ping()
            if TerminalLauncher.isKernelInstalled {
                state = .running(version: health.apiServerVersion)
            } else {
                state = .readyButNoKernel(version: health.apiServerVersion)
            }
        } catch {
            state = .unavailable
        }
    }

    /// Start the system. If no kernel is installed, brings up the apiserver first
    /// (without a kernel), then downloads the kernel via XPC with real progress.
    /// GitHub connectivity determines the download URL (original vs mirror).
    ///
    /// A cancelled or failed kernel install aborts the whole flow — the system
    /// is never started without a kernel (state stays `.readyButNoKernel`).
    func startSystem() async {
        // Prevent re-entry while already running (e.g. user double-clicks).
        guard !isBusy else { return }

        // Cancel any in-flight kernel download from a previous attempt.
        kernelTask?.cancel()
        kernelTask = nil

        isBusy = true
        actionError = nil
        kernelError = nil
        kernelProgress = nil
        defer { isBusy = false; statusHint = nil }

        // Kernel already present → just start.
        if TerminalLauncher.isKernelInstalled {
            await runStart(.none)
            return
        }

        // Bring up apiserver without a kernel (--disable-kernel-install).
        // The apiserver starts in seconds; kernel download happens separately.
        statusHint = "Starting service…"
        await runStart(.skip)
        guard isApiserverUp else {
            actionError = OperationError(
                title: "Failed to start the system",
                detail: "The container service did not start. Please try again.")
            return
        }

        // Now download the kernel via XPC (with real progress).
        // Probe GitHub connectivity to decide the URL.
        statusHint = "Checking network…"
        let kernelURL: URL
        do {
            kernelURL = try await SystemConfig.load().kernel.url
        } catch {
            kernelError = (title: "Kernel download failed", message: error.localizedDescription)
            return
        }
        if await canReachGitHub() {
            statusHint = nil
            await installKernel(url: kernelURL)
        } else {
            statusHint = nil
            await installKernelViaMirror()
        }
    }

    /// Run `container system start` with the given kernel-install mode, then ping.
    private func runStart(_ mode: TerminalLauncher.KernelInstallMode) async {
        do {
            try await Task.detached { try TerminalLauncher.startSystem(kernelInstall: mode) }.value
        } catch {
            actionError = OperationError(
                title: "Failed to start the system", detail: error.localizedDescription)
        }
        await refreshState()
    }

    func stopSystem() async {
        kernelTask?.cancel()
        kernelTask = nil
        kernelProgress = nil
        kernelError = nil
        isBusy = true
        actionError = nil
        statusHint = nil
        defer { isBusy = false; statusHint = nil }
        do {
            try await Task.detached { try TerminalLauncher.stopSystem() }.value
        } catch {
            actionError = OperationError(
                title: "Failed to stop the system", detail: error.localizedDescription)
        }
        await refreshState()
    }

    /// Open the container project's releases page to guide installation.
    func openInstallPage() {
        if let url = URL(string: "https://github.com/apple/container/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    func clearActionError() { actionError = nil }

    // MARK: - Kernel mirror download

    /// GitHub proxy domains tried in order when downloading via a mirror.
    private static let githubProxyDomains = ["gh-proxy.com", "ghfast.top", "gh-ddlc.top"]

    /// Lightweight reachability probe: a HEAD request to GitHub with a short
    /// timeout, so mainland-China users don't wait for the CLI to time out.
    private func canReachGitHub() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        var request = URLRequest(url: URL(string: "https://github.com")!)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: config)
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }

    /// Install the kernel from a given URL via XPC, reporting real progress.
    private func installKernel(url: URL) async {
        let config: ContainerSystemConfig
        do { config = try await SystemConfig.load() }
        catch { kernelError = (title: "Kernel download failed", message: error.localizedDescription); return }

        let progress = OperationProgress(phaseLabel: "Downloading kernel…")
        kernelProgress = progress
        defer { kernelProgress = nil }

        do {
            try await ClientKernel.installKernelFromTar(
                tarFile: url.absoluteString,
                kernelFilePath: config.kernel.binaryPath,
                platform: .current,
                progressUpdate: { [weak self] events in
                    await self?.applyKernelProgress(events)
                },
                force: true)
            await refreshState()
        } catch is CancellationError {
            kernelError = (
                title: "Kernel required",
                message: "The kernel download was cancelled. The kernel is required to run containers and machines.")
        } catch {
            // Fallback: try mirrors automatically
            await installKernelViaMirror(config: config)
        }
    }

    /// Install the kernel via GitHub mirrors, reporting real progress. Tries each
    /// proxy domain in turn. The apiserver must already be running (XPC call).
    private func installKernelViaMirror() async {
        let config: ContainerSystemConfig
        do { config = try await SystemConfig.load() }
        catch { kernelError = (title: "Kernel download failed", message: error.localizedDescription); return }
        await installKernelViaMirror(config: config)
    }

    private func installKernelViaMirror(config: ContainerSystemConfig) async {
        let originalURL = config.kernel.url.absoluteString
        let binaryPath = config.kernel.binaryPath
        let platform = SystemPlatform.current

        if kernelProgress == nil {
            kernelProgress = OperationProgress(phaseLabel: "Downloading kernel via mirror…")
        }
        defer { kernelProgress = nil }

        var lastError: Error?
        for domain in Self.githubProxyDomains {
            if Task.isCancelled { return }
            let mirrorURL = "https://\(domain)/\(originalURL)"
            do {
                try await ClientKernel.installKernelFromTar(
                    tarFile: mirrorURL,
                    kernelFilePath: binaryPath,
                    platform: platform,
                    progressUpdate: { [weak self] events in
                        await self?.applyKernelProgress(events)
                    },
                    force: true)
                await refreshState()  // kernel installed → refresh state
                return
            } catch is CancellationError {
                kernelError = (
                    title: "Kernel required",
                    message: "The kernel download was cancelled. The kernel is required to run containers and machines.")
                return
            } catch {
                lastError = error  // try the next mirror
            }
        }

        kernelError = (
            title: "Kernel download failed",
            message: "Could not download the kernel from any mirror. Check your network.\n\n\(lastError?.localizedDescription ?? "unknown error")")
    }

    private func applyKernelProgress(_ events: [ProgressUpdateEvent]) {
        // The phase/byte logic lives on `OperationProgress` (including the
        // kernel's unpack-phase byte suppression). In-place mutation means there
        // is no copy to forget to write back — the bug that previously left the
        // bar reading as indeterminate while the download actually ran.
        kernelProgress?.apply(events)
    }

    func cancelKernelDownload() {
        kernelTask?.cancel()
        kernelTask = nil
        kernelProgress = nil
        isBusy = false
        statusHint = nil
        kernelError = (
            title: "Kernel required",
            message: "The kernel is required to run containers and machines. The download was cancelled.")

        // The XPC download runs inside the apiserver daemon — cancelling the
        // Swift Task only drops our side of the connection. To actually stop the
        // download, we must stop the daemon. Fire-and-forget; the next polling
        // cycle will detect the daemon has stopped and update state to .unavailable.
        Task.detached {
            try? TerminalLauncher.stopSystem()
        }
    }

    func retryKernelDownload() {
        // Cancel any in-flight download and wait for cleanup.
        kernelTask?.cancel()
        kernelTask = nil
        kernelProgress = nil
        kernelError = nil
        // Now start fresh — guard !isBusy in startSystem() was blocking because
        // the old task's defer hasn't run yet. Reset it here since we're taking over.
        isBusy = false
        statusHint = nil
        Task { await startSystem() }
    }
}
