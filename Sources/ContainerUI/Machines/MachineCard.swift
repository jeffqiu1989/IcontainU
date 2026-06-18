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

import MachineAPIClient
import SwiftUI

/// A colorful card for a single machine, matching the container card style.
/// Three states: default (thin colored border), hover (deeper shadow),
/// selected (thick left accent bar + thicker border).
struct MachineCard: View {
    let machine: MachineSnapshot
    let isDefault: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onBoot: () -> Void
    let onStop: () -> Void
    let onRun: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var isRunning: Bool { machine.status == .running }

    private var palette: CardPalette {
        CardPalette(color: Palette.machines)
    }

    private var ipText: String { machine.ipAddress ?? "No address" }

    private var distro: LinuxDistro {
        LinuxDistro(imageReference: machine.configuration.image.reference)
    }

    private var diskText: String? {
        machine.diskSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack {
                DistroChip(distro: distro)
                Spacer(minLength: 0)
            }
            infoRow(icon: "network", text: ipText, secondary: machine.ipAddress == nil)
            infoRow(icon: "internaldrive", text: diskText ?? "Unknown size", secondary: diskText == nil)
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Palette.cardBorder, lineWidth: isSelected ? 2 : 1)
        }
        .shadow(
            color: .black.opacity(isSelected ? 0.24 : (hovering ? 0.10 : 0.03)),
            radius: isSelected ? 12 : (hovering ? 5 : 2), y: isSelected ? 3 : 1
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(machine.id)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if isDefault {
                Text("default")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.tagFill, in: Capsule())
                    .foregroundStyle(palette.tagText)
            }
            Spacer(minLength: 4)
            StatusBadge(status: machine.status)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            actionButton(icon: "play.fill", tint: .green, help: "Boot", disabled: isRunning, action: onBoot)
            actionButton(icon: "stop.fill", tint: .orange, help: "Stop", disabled: !isRunning, action: onStop)
            actionButton(
                icon: "terminal", tint: .blue, help: "Open shell", disabled: false, action: onRun)
            actionButton(icon: "trash", tint: .red, help: "Delete", disabled: false, action: onDelete)
        }
        .padding(.top, 2)
    }

    private func actionButton(
        icon: String, tint: Color, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .frame(width: 26, height: 16)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(tint)
        .disabled(disabled)
        .help(help)
    }

    private func infoRow(icon: String, text: String, secondary: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(palette.accent.opacity(0.8))
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .foregroundStyle(secondary ? Color.secondary.opacity(0.7) : Color.primary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
