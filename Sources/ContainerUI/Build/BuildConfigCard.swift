import SwiftUI

/// A card for one build configuration — a Dockerfile + context + tags + options.
/// Collapsed it shows the tag, a status badge, and chip summary (platform,
/// Dockerfile, last duration). Expanded it reveals the full config detail.
/// Build / View Log / Delete actions stay visible in both states, mirroring
/// `ComposeProjectCard`'s chrome exactly.
struct BuildConfigCard: View {
    let config: BuildConfigView
    /// True when ANY build is running (serial builds — every card's Build
    /// button disables, not just this one's).
    let buildDisabled: Bool
    let onBuild: () -> Void
    let onViewLog: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var expanded = false

    private var palette: CardPalette { CardPalette(color: Palette.build) }
    private var record: BuildConfigRecord { config.record }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if expanded {
                detailList
            } else {
                chipRow
            }
            Divider()
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.border, lineWidth: expanded ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        }
        .shadow(
            color: .black.opacity(expanded ? 0.24 : (hovering ? 0.10 : 0.03)),
            radius: expanded ? 12 : (hovering ? 5 : 2), y: expanded ? 3 : 1
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: expanded)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "hammer")
                .font(.body)
                .foregroundStyle(palette.accent)
            Text(record.primaryTag)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if record.isComposeDerived {
                Text("Compose")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Palette.compose.opacity(0.18), in: Capsule())
                    .foregroundStyle(Palette.compose)
                    .help(composeHelp)
            }
            Spacer(minLength: 0)
            if config.isBuilding {
                ProgressView()
                    .controlSize(.small)
            }
            statusBadge
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 0 : -90))
        }
    }

    private var composeHelp: LocalizedStringKey {
        if case .compose(let project, let service) = record.source {
            return "Managed by compose project \"\(project)\" (service \"\(service)\"). Re-up the project to apply a rebuilt image."
        }
        return ""
    }

    @ViewBuilder
    private var statusBadge: some View {
        if config.isBuilding {
            badge("Building…", color: Palette.build)
        } else if let outcome = record.lastBuild {
            switch outcome.status {
            case .succeeded: badge("Succeeded", color: .green)
            case .failed: badge("Failed", color: .red)
            }
        } else {
            badge("Not built", color: .gray)
        }
    }

    private func badge(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: Collapsed chips

    private var chipRow: some View {
        HStack(spacing: 6) {
            chip(record.dockerfile.lastPathComponent, icon: "doc.text")
            if !record.platforms.isEmpty {
                chip(record.platforms.map { $0.replacingOccurrences(of: "linux/", with: "") }
                    .joined(separator: "+"), icon: "cpu")
            }
            if !record.target.isEmpty {
                chip(record.target, icon: "target")
            }
            if let outcome = record.lastBuild {
                chip(String(format: "%.1fs", outcome.duration), icon: "clock")
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.callout.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(palette.tagFill, in: Capsule())
        .foregroundStyle(palette.tagText)
    }

    // MARK: Expanded detail

    private var detailList: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Context", record.contextDirPath)
            detailRow("Dockerfile", record.dockerfilePath)
            detailRow("Tags", record.tags.joined(separator: ", "))
            if !record.platforms.isEmpty {
                detailRow("Platform", record.platforms.joined(separator: ", "))
            }
            if !record.target.isEmpty {
                detailRow("Target", record.target)
            }
            if !record.buildArgs.isEmpty {
                detailRow("Build args", record.buildArgs.joined(separator: ", "))
            }
            if record.noCache || record.pull {
                detailRow(
                    "Options",
                    [record.noCache ? "no-cache" : nil, record.pull ? "pull" : nil]
                        .compactMap { $0 }.joined(separator: ", "))
            }
        }
    }

    private func detailRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: Actions

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(showTitles: true)
            actionRow(showTitles: false)
        }
        .padding(.top, 2)
    }

    private func actionRow(showTitles: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            actionButton(
                record.lastBuild == nil ? "Build" : "Rebuild",
                icon: "hammer.fill", tint: Palette.build,
                help: record.isComposeDerived
                    ? "Rebuild the image (re-up the compose project to apply)"
                    : "Build the image",
                showTitle: showTitles,
                disabled: buildDisabled, action: onBuild)
            actionButton(
                "Log", icon: "text.alignleft", tint: .blue,
                help: "View build log",
                showTitle: showTitles,
                disabled: !config.isBuilding && record.lastBuild == nil,
                action: onViewLog)
            if !record.isComposeDerived {
                actionButton(
                    "Edit", icon: "pencil", tint: .secondary,
                    help: "Edit build config",
                    showTitle: showTitles,
                    disabled: config.isBuilding, action: onEdit)
                actionButton(
                    "Delete", icon: "trash", tint: .red,
                    help: "Delete build config (built images are kept)",
                    showTitle: showTitles,
                    disabled: config.isBuilding, action: onDelete)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func actionButton(
        _ title: LocalizedStringKey, icon: String, tint: Color, help: LocalizedStringKey,
        showTitle: Bool, disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionLabel(title, icon: icon, tint: tint, showTitle: showTitle, disabled: disabled)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }

    @ViewBuilder
    private func actionLabel(
        _ title: LocalizedStringKey, icon: String, tint: Color, showTitle: Bool, disabled: Bool
    ) -> some View {
        let chrome = RoundedRectangle(cornerRadius: 6)
        if showTitle {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.body).foregroundStyle(tint)
                Text(title).font(.caption)
            }
            .frame(height: 16)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .frame(minWidth: 72)
            .background(Color(.windowBackgroundColor), in: chrome)
            .overlay { chrome.strokeBorder(tint.opacity(0.5), lineWidth: 1) }
            .opacity(disabled ? 0.3 : 1)
        } else {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 32, height: 16)
                .padding(4)
                .background(Color(.windowBackgroundColor), in: chrome)
                .overlay { chrome.strokeBorder(tint.opacity(0.5), lineWidth: 1) }
                .opacity(disabled ? 0.3 : 1)
        }
    }
}
