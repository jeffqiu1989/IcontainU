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

import SwiftUI

/// Always-on system status footer pinned to the bottom of the sidebar, following
/// the macOS convention (Xcode/Finder). Single line to fit the narrow sidebar;
/// the version is available on hover rather than crowding the footer.
struct SystemStatusBar: View {
    @Environment(SystemModel.self) private var system

    private var indicatorColor: Color {
        switch system.state {
        case .running: .green
        case .unavailable: .orange
        case .notInstalled: .red
        case .unknown: .secondary
        }
    }

    private var label: String {
        switch system.state {
        case .running: return "System running"
        case .unavailable: return "System not running"
        case .notInstalled: return "Not installed"
        case .unknown: return "Checking…"
        }
    }

    private var tooltip: String {
        if let version = system.versionDescription {
            return "\(label) · apiserver \(version)"
        }
        return label
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(tooltip)
    }

    @ViewBuilder
    private var actionButton: some View {
        if system.isBusy {
            ProgressView().controlSize(.small)
        } else {
            switch system.state {
            case .running:
                button("stop.fill", help: "Stop system") {
                    Task { await system.stopSystem() }
                }
            case .unavailable:
                button("play.fill", help: "Start system") {
                    Task { await system.startSystem() }
                }
            case .notInstalled:
                button("arrow.down.circle", help: "Install container") {
                    system.openInstallPage()
                }
            case .unknown:
                EmptyView()
            }
        }
    }

    private func button(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Shown over the content area when the system is not usable (not running or not
/// installed), with the matching call to action.
struct SystemUnavailableOverlay: View {
    @Environment(SystemModel.self) private var system

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: system.state == .notInstalled ? "shippingbox" : "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            if system.state == .notInstalled {
                Text("`container` is not installed.")
                    .font(.headline)
                Text("Install the container CLI to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Download container…") { system.openInstallPage() }
                    .controlSize(.large)
            } else {
                Text("The container system is not running.")
                    .font(.headline)
                Button {
                    Task { await system.startSystem() }
                } label: {
                    if system.isBusy {
                        VStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            if let hint = system.statusHint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Start System")
                    }
                }
                .controlSize(.large)
                .disabled(system.isBusy)
            }

            if let error = system.actionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.92))
    }
}
