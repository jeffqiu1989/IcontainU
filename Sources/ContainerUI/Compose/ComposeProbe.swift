import Foundation
import Logging
import TerminalProgress

/// Runs a compose `healthcheck:` probe against a running container until it
/// reports healthy, or until `retries` consecutive failures accrue after the
/// `start_period` grace window (in which case it throws
/// `.serviceUnhealthy`). `ComposeEngine.up` uses this to honor
/// `depends_on: {condition: service_healthy}`: a dependent service is not
/// created until each gated dependency is healthy.
///
/// The state lives only for the duration of one Up pass — nothing is persisted
/// and no background polling continues after the gate resolves. Run-time
/// health monitoring (an always-on healthy/unhealthy badge) is intentionally out
/// of scope; this type exists solely to sequence startup correctly.
struct ComposeProbe {
    private static let log = Logger(label: "icontainu.compose.probe")

    private let spec: ComposeHealthcheck
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private let retries: Int

    init(spec: ComposeHealthcheck) {
        self.spec = spec
        // Clamp to sane positives so a malformed file can't make the loop spin
        // furiously or stall on a zero-length probe.
        self.interval = max(spec.interval, 1)
        self.timeout = max(spec.timeout, 1)
        self.retries = max(spec.retries, 1)
    }

    /// Run the probe until the container is healthy, or throw
    /// `.serviceUnhealthy(service:dependency:)`. `beginPhase` relabels the Up
    /// progress bar (e.g. "app: waiting for db to be healthy…"); the handler it
    /// returns is unused — a health wait has no byte progress, so the bar stays
    /// indeterminate, which is the right read for "waiting".
    ///
    /// Docker semantics honored: failures during `start_period` don't count
    /// toward `retries`; any single success resolves the gate immediately.
    func waitUntilHealthy(
        containerID: String,
        service: String,
        dependency: String,
        beginPhase: @escaping @Sendable (String) async -> ProgressUpdateHandler
    ) async throws {
        _ = await beginPhase("\(service): waiting for \(dependency) to be healthy…")

        let startedAt = Date()
        var lastProbeAt: Date = .distantPast
        var consecutiveFailures = 0

        while true {
            try Task.checkCancellation()
            let now = Date()

            // Probe once per interval. The first iteration runs immediately
            // (lastProbeAt is distantPast), then at most every `interval`.
            if now.timeIntervalSince(lastProbeAt) >= interval {
                lastProbeAt = now
                let healthy = try await runProbe(containerID: containerID)
                if healthy {
                    Self.log.info("healthcheck passed", metadata: ["id": "\(containerID)"])
                    return
                }
                // A failure (or a timed-out probe). During start_period the
                // grace window absorbs it; afterward it counts toward retries.
                let elapsed = now.timeIntervalSince(startedAt)
                if elapsed >= spec.startPeriod {
                    consecutiveFailures += 1
                    Self.log.debug("healthcheck failed", metadata: [
                        "id": "\(containerID)",
                        "failures": "\(consecutiveFailures)",
                        "retries": "\(retries)",
                        "elapsed": "\(Int(elapsed))s",
                    ])
                    if consecutiveFailures >= retries {
                        throw ComposeError.serviceUnhealthy(
                            service: service, dependency: dependency)
                    }
                } else {
                    Self.log.debug("healthcheck failed within start_period (ignored)", metadata: [
                        "id": "\(containerID)",
                        "elapsed": "\(Int(elapsed))s",
                        "start_period": "\(Int(spec.startPeriod))s",
                    ])
                }
            }

            // Sleep in small ticks (≤1s) so cancellation stays responsive even
            // when a service sets a long interval.
            let tick = min(interval, 1.0)
            try await Task.sleep(for: .seconds(tick))
        }
    }

    /// Run one probe, returning whether it succeeded. A timeout (from
    /// `ContainerExec.runProbe`) counts as a failure. A missing `container`
    /// binary propagates as a hard environment error.
    private func runProbe(containerID: String) async throws -> Bool {
        switch spec.probe {
        case .cmd(let argv):
            // Direct exec of the argv — `container exec <id> pg_isready …`.
            guard let cmd = argv.first else { return false }
            return try await ContainerExec.runProbe(
                id: containerID, command: cmd,
                args: Array(argv.dropFirst()), timeout: timeout)
        case .cmdShell(let script):
            // `container exec` doesn't run a shell by default, so CMD-SHELL is
            // wrapped explicitly: `container exec <id> /bin/sh -c "<script>"`.
            return try await ContainerExec.runProbe(
                id: containerID, command: "/bin/sh",
                args: ["-c", script], timeout: timeout)
        case .none:
            // The engine only registers non-disabled probes, so this is
            // unreachable in practice; treat a disabled check as healthy.
            return true
        }
    }
}
