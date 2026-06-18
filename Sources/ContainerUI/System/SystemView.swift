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

import ContainerPersistence
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
    @State private var model = SystemConfigModel()

    var body: some View {
        Group {
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
        .task { await model.load() }
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
                    row("Rosetta", config.build.rosetta ? "Enabled" : "Disabled")
                    row("Image", config.build.image)
                }
                section("DNS") {
                    row("Domain", config.dns.domain ?? "Not set")
                }
                section("Network") {
                    row("IPv4 Subnet", config.network.subnet?.description ?? "Auto-allocated")
                    row("IPv6 Subnet", config.network.subnetv6?.description ?? "Auto-allocated")
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
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
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
