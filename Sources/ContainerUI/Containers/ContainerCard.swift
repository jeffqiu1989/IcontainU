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

import ContainerResource
import Foundation
import SwiftUI

/// A colorful card for a single container, sized for a two-column grid. Each card
/// gets a stable accent color. Three states: default (thin colored border), hover
/// (deeper shadow), selected (thick left accent bar + thicker border).
///
/// The network, port, and mount rows render their values as outlined chips laid
/// out on a single line, fitting as many as the width allows; the rest collapse
/// into a tappable "+N" badge that expands that row in place — networks and ports
/// wrap onto further lines, mounts list vertically with full paths. Tapping an IP
/// chip copies the address, a port chip copies `host:port`, a mount chip reveals
/// the source in Finder.
struct ContainerCard: View {
    let container: ContainerSnapshot
    let isSelected: Bool
    let onSelect: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onExec: () -> Void
    let onLogs: () -> Void
    let onDelete: () -> Void
    let onCopy: (String) -> Void

    @State private var hovering = false
    @State private var expandedNet = false
    @State private var expandedPorts = false
    @State private var expandedMounts = false
    @State private var netOverflow = 0
    @State private var portOverflow = 0
    @State private var mountOverflow = 0

    private var isRunning: Bool { container.status == .running }

    private var palette: CardPalette {
        CardPalette(color: Palette.containers)
    }

    private var parsedImage: ParsedImageReference {
        ParsedImageReference(container.configuration.image.reference)
    }

    private var networks: [Attachment] { container.networks }
    private var ports: [PublishPort] { container.configuration.publishedPorts }
    private var mounts: [Filesystem] { container.configuration.mounts }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            imageRow
            networkRow
            portsRow
            mountRow
            Divider()
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Palette.cardBorder, lineWidth: isSelected ? 3 : 1)
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
        .animation(.easeOut(duration: 0.15), value: expandedNet)
        .animation(.easeOut(duration: 0.15), value: expandedPorts)
        .animation(.easeOut(duration: 0.15), value: expandedMounts)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(container.id)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            StatusBadge(status: container.status)
        }
    }

    private var imageRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "opticaldiscdrive")
                .font(.body)
                .foregroundStyle(palette.accent)
                .frame(width: 16)
            Text(parsedImage.repository)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            if let tag = parsedImage.tag {
                Text(tag)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.tagFill, in: Capsule())
                    .foregroundStyle(palette.tagText)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Network row

    @ViewBuilder
    private var networkRow: some View {
        rowContainer(icon: "network", accent: Palette.network, isEmpty: networks.isEmpty, emptyText: "No address") {
            if expandedNet {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(networks.enumerated()), id: \.offset) { _, net in
                        let ip = net.ipv4Address.address.description
                        dataChip(ip, accent: Palette.network) { copy(ip) }
                    }
                    collapseBadge(accent: Palette.network) { expandedNet = false }
                }
            } else {
                SingleLineFitLayout(spacing: 8, overflow: $netOverflow) {
                    ForEach(Array(networks.enumerated()), id: \.offset) { _, net in
                        let ip = net.ipv4Address.address.description
                        dataChip(ip, accent: Palette.network) { copy(ip) }
                    }
                    moreBadge(netOverflow, accent: Palette.network) { expandedNet = true }
                }
            }
        }
    }

    // MARK: Ports row

    @ViewBuilder
    private var portsRow: some View {
        rowContainer(icon: "powerplug", accent: Palette.port, isEmpty: ports.isEmpty, emptyText: "No ports") {
            if expandedPorts {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(Array(ports.enumerated()), id: \.offset) { _, port in
                        dataChip(portLabel(port), accent: Palette.port) { copy(portCopy(port)) }
                    }
                    collapseBadge(accent: Palette.port) { expandedPorts = false }
                }
            } else {
                SingleLineFitLayout(spacing: 8, overflow: $portOverflow) {
                    ForEach(Array(ports.enumerated()), id: \.offset) { _, port in
                        dataChip(portLabel(port), accent: Palette.port) { copy(portCopy(port)) }
                    }
                    moreBadge(portOverflow, accent: Palette.port) { expandedPorts = true }
                }
            }
        }
    }

    // MARK: Mount row

    @ViewBuilder
    private var mountRow: some View {
        rowContainer(icon: "folder", accent: Palette.mount, isEmpty: mounts.isEmpty, emptyText: "No mounts") {
            if expandedMounts {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(mounts.enumerated()), id: \.offset) { _, mount in
                        mountFullRow(mount)
                    }
                    HStack {
                        collapseBadge(accent: Palette.mount) { expandedMounts = false }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                SingleLineFitLayout(spacing: 8, overflow: $mountOverflow) {
                    ForEach(Array(mounts.enumerated()), id: \.offset) { _, mount in
                        dataChip(mountLabel(mount), accent: Palette.mount) { openInFinder(mount.source) }
                    }
                    moreBadge(mountOverflow, accent: Palette.mount) { expandedMounts = true }
                }
            }
        }
    }

    /// A full-width row for one mount when the mount row is expanded: the complete
    /// `source:destination` mapping, tail-truncated if it overruns, tappable to
    /// reveal the host source in Finder.
    private func mountFullRow(_ mount: Filesystem) -> some View {
        Button {
            openInFinder(mount.source)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption)
                    .foregroundStyle(Palette.mount)
                Text(mountLabel(mount))
                    .font(.callout)
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.mount.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Palette.mount.opacity(0.45), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("在 Finder 中打开 \(mount.source)")
    }

    // MARK: Row scaffolding

    /// Lays out a labeled row: a fixed-width leading icon tinted with the row's
    /// semantic color, then the chip content stretched to full width so the
    /// single-line layout knows its budget.
    private func rowContainer<C: View>(
        icon: String, accent: Color, isEmpty: Bool, emptyText: String, @ViewBuilder content: () -> C
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            rowIcon(icon, accent: accent)
                .padding(.top, 3)
            if isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .padding(.top, 3)
                Spacer(minLength: 0)
            } else {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func dataChip(_ text: String, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .foregroundStyle(Color.primary.opacity(0.8))
                .outlinedChip(accent: accent)
        }
        .buttonStyle(.plain)
    }

    /// The "+N" expand badge. Zero count renders nothing (the fit layout collapses
    /// it), so it only appears when chips actually overflowed.
    @ViewBuilder
    private func moreBadge(_ count: Int, accent: Color, action: @escaping () -> Void) -> some View {
        if count > 0 {
            Button(action: action) {
                Text("+\(count)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help("展开查看全部")
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func collapseBadge(accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("收起")
                .font(.callout.weight(.semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("收起")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            actionButton(icon: "play.fill", tint: .green, help: "Start", disabled: isRunning, action: onStart)
            actionButton(icon: "stop.fill", tint: .orange, help: "Stop", disabled: !isRunning, action: onStop)
            actionButton(
                icon: "terminal", tint: .blue, help: "Open shell", disabled: !isRunning, action: onExec)
            actionButton(icon: "doc.text", tint: .indigo, help: "Logs", disabled: false, action: onLogs)
            actionButton(icon: "trash", tint: .red, help: "Delete", disabled: false, action: onDelete)
        }
        .padding(.top, 2)
    }

    private func actionButton(
        icon: String, tint: Color, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 32, height: 16)
                .padding(4)
                .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(tint.opacity(0.5), lineWidth: 1)
                }
                .opacity(disabled ? 0.3 : 1)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }

    private func rowIcon(_ name: String, accent: Color) -> some View {
        Image(systemName: name)
            .font(.body)
            .foregroundStyle(accent)
            .frame(width: 16)
    }

    // MARK: Values

    private func portLabel(_ p: PublishPort) -> String {
        "\(p.hostPort)→\(p.containerPort)/\(p.proto.rawValue)"
    }

    private func portCopy(_ p: PublishPort) -> String {
        // 0.0.0.0 means "listen on all interfaces" — not a reachable address.
        // Copy a loopback host so the pasted value is directly usable.
        let address = "\(p.hostAddress)"
        let host = (address == "0.0.0.0" || address.isEmpty) ? "127.0.0.1" : address
        return "\(host):\(p.hostPort)"
    }

    /// A mount's `source:destination` mapping. Named volumes show their volume name
    /// as the source; bind mounts show the host path.
    private func mountLabel(_ mount: Filesystem) -> String {
        let src = mount.volumeName ?? mount.source
        return "\(src):\(mount.destination)"
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        onCopy(value)
    }

    private func openInFinder(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
