import ContainerAPIClient
import ContainerResource
import Foundation
import Observation
import SwiftUI

/// Polls a container's resource stats. CPU percentage is derived from the delta
/// in cumulative CPU microseconds between two samples over wall-clock time.
@Observable
@MainActor
final class ContainerStatsModel {
    private(set) var stats: ContainerStats?
    private(set) var cpuPercent: Double?
    private(set) var errorMessage: String?
    private(set) var loaded = false

    private let containerID: String
    // Fresh client per use (cached XPC connections go invalid across apiserver
    // restarts). See ContainersModel for the rationale.
    private var client: ContainerClient { ContainerClient() }
    private var lastCPUUsec: UInt64?
    private var lastSampleTime: Date?

    init(containerID: String) {
        self.containerID = containerID
    }

    func startPolling() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refresh() async {
        do {
            let now = Date()
            let snapshot = try await client.stats(id: containerID)

            if let cpuUsec = snapshot.cpuUsageUsec,
                let prevUsec = lastCPUUsec,
                let prevTime = lastSampleTime
            {
                let elapsed = now.timeIntervalSince(prevTime)
                if elapsed > 0, cpuUsec >= prevUsec {
                    let deltaUsec = Double(cpuUsec - prevUsec)
                    cpuPercent = (deltaUsec / 1_000_000.0) / elapsed * 100.0
                }
            }
            lastCPUUsec = snapshot.cpuUsageUsec
            lastSampleTime = now

            stats = snapshot
            loaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The Stats tab: live resource usage for a container.
struct ContainerStatsTab: View {
    let containerID: String
    @State private var model: ContainerStatsModel

    init(containerID: String) {
        self.containerID = containerID
        _model = State(initialValue: ContainerStatsModel(containerID: containerID))
    }

    var body: some View {
        Group {
            if let error = model.errorMessage, model.stats == nil {
                VStack(spacing: 8) {
                    ErrorBanner(message: error)
                    Spacer()
                }
            } else if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let stats = model.stats {
                content(stats)
            } else {
                ContentUnavailableView("No Stats", systemImage: "chart.bar")
            }
        }
        .task {
            await model.startPolling()
        }
    }

    private func content(_ stats: ContainerStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                cpuSection
                memorySection(stats)
                ioSection(stats)
            }
            .padding(16)
        }
    }

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("CPU")
            if let pct = model.cpuPercent {
                HStack {
                    Text(String(format: "%.1f%%", pct))
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Spacer()
                }
                ProgressView(value: min(pct / 100.0, 1.0))
            } else {
                Text("Measuring…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func memorySection(_ stats: ContainerStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Memory")
            let used = stats.memoryUsageBytes ?? 0
            let limit = stats.memoryLimitBytes
            HStack {
                Text(byteString(used))
                    .font(.title3.weight(.semibold).monospacedDigit())
                if let limit, limit > 0 {
                    Text("/ \(byteString(limit))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let limit, limit > 0 {
                ProgressView(value: min(Double(used) / Double(limit), 1.0))
            }
        }
    }

    private func ioSection(_ stats: ContainerStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("I/O")
            metricRow("Network RX", stats.networkRxBytes.map(byteString) ?? "—")
            metricRow("Network TX", stats.networkTxBytes.map(byteString) ?? "—")
            metricRow("Block Read", stats.blockReadBytes.map(byteString) ?? "—")
            metricRow("Block Write", stats.blockWriteBytes.map(byteString) ?? "—")
            metricRow("Processes", stats.numProcesses.map { "\($0)" } ?? "—")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
