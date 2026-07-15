import ContainerPersistence
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class SystemConfigModel {
    private(set) var config: ContainerSystemConfig?
    private(set) var errorMessage: String?
    private(set) var loaded = false

    func load() async {
        do {
            config = try await SystemConfig.load()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loaded = true
    }
}

/// Read-only display of the effective `config.toml` system configuration.
struct SystemView: View {
    @Environment(SystemModel.self) private var system
    @State private var model = SystemConfigModel()
    @State private var language = AppLanguage.current
    @State private var proxy = ProxyConfig.current
    @State private var showRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            languageSection
                .padding(16)
            Divider()
            proxySection
                .padding(16)
            Divider()
            configArea
        }
        .task { await model.load() }
    }

    private var proxySection: some View {
        ProxyConfigSection(
            config: $proxy,
            onRestart: system.isRunning ? { restartSystem() } : nil)
    }

    /// Restart the container system so a proxy change takes effect (proxy env is
    /// injected at `container system start`). Stop then start.
    private func restartSystem() {
        Task {
            await system.stopSystem()
            await system.startSystem()
        }
    }

    @ViewBuilder
    private var configArea: some View {
        if let error = model.errorMessage {
            VStack {
                ErrorBanner(message: error)
                Spacer()
            }
        } else if !model.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let config = model.config {
            content(config)
        } else {
            ContentUnavailableView("No Configuration", systemImage: "gearshape")
        }
    }

    /// In-app language picker. Always visible at the top of the System view so the
    /// 中英文 switch is reachable even before the container config loads. Changing
    /// it writes `AppleLanguages` and prompts to relaunch (see `AppLanguage`).
    /// Label + dropdown on one row, native Picker styled to match MCPView's Bind
    /// field (`.labelsHidden()`), so it reads as a settings row, not a section.
    private var languageSection: some View {
        HStack(spacing: 8) {
            Text("Language")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("", selection: $language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.localizedName).tag(lang)
                }
            }
            .labelsHidden()
            .frame(width: 220, alignment: .leading)
            .onChange(of: language) { _, new in
                new.apply()
                showRestart = true
            }
            Spacer(minLength: 0)
        }
        .alert("Restart required", isPresented: $showRestart) {
            Button("Later", role: .cancel) {}
            Button("Restart") { relaunch() }
        } message: {
            Text("Language changes take effect after restarting the app.")
        }
    }

    /// Relaunch the app so the new `AppleLanguages` takes effect. `open -n` starts a
    /// fresh instance and `exit(0)` quits this one. Only meaningful for a packaged
    /// .app; dev `swift run` shows English regardless, so the prompt is moot there.
    private func relaunch() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        exit(0)
    }

    private func content(_ config: ContainerSystemConfig) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("System configuration (read-only). Edit via `container` CLI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                section("Container Defaults") {
                    row("CPUs", "\(config.container.cpus)")
                    row("Memory", config.container.memory.description)
                }
                section("Builder") {
                    row("CPUs", "\(config.build.cpus)")
                    row("Memory", config.build.memory.description)
                    row("Rosetta", config.build.rosetta ? String(localized: "Enabled") : String(localized: "Disabled"))
                    row("Image", config.build.image)
                }
                section("DNS") {
                    row("Domain", config.dns.domain ?? String(localized: "Not set"))
                }
                section("Network") {
                    row("IPv4 Subnet", config.network.subnet?.description ?? String(localized: "Auto-allocated"))
                    row("IPv6 Subnet", config.network.subnetv6?.description ?? String(localized: "Auto-allocated"))
                }
                section("Registry") {
                    row("Domain", config.registry.domain)
                }
                section("Kernel") {
                    row("Binary Path", config.kernel.binaryPath)
                    row("URL", config.kernel.url.absoluteString)
                }
                section("VM Init") {
                    row("Image", config.vminit.image)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
