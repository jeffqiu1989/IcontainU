import ContainerResource
import SwiftUI

/// A card for one compose project. Collapsed (the default) it shows the project
/// name, a running/total health badge, and a single-line row of status-colored
/// service chips - green for running, red for failed (non-zero exit), gray for
/// exited, dashed for not-yet-created. Expanding reveals the full per-service
/// rows (status pill + logs). The Up / Start / Stop / Down / Remove actions stay
/// visible in both states, so primary controls are always one click away.
struct ComposeProjectCard: View {
    let project: ComposeProjectView
    /// True when any operation (Up, Start, Stop, Down) is running on this project.
    let isActive: Bool
    /// True when some container in this project couldn't receive its `/etc/hosts`
    /// service-discovery block (e.g. an image without `/bin/sh`).
    let hostsDegraded: Bool
    let onUp: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onDown: () -> Void
    let onRemove: () -> Void
    /// Open a service's logs (passes the backing container id).
    let onServiceLogs: (String) -> Void

    @State private var hovering = false
    /// Card-level expand: collapsed shows the chip summary, expanded shows the
    /// full per-service rows. Mirrors `ImageRepoCard`'s expand mechanic.
    @State private var expanded = false
    /// Overflow count reported by `SingleLineFitLayout` - drives the "+N" chip
    /// that expands the card when services don't fit on one line.
    @State private var chipOverflow = 0

    private var palette: CardPalette { CardPalette(color: Palette.compose) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if expanded {
                serviceList
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
        // Tap anywhere on the card - header, chips, divider, padding, border - to
        // expand/collapse. Action buttons (and the service-list logs buttons) are
        // controls, so they consume their own taps and don't toggle; only non-button
        // areas do. contentShape is the full rounded rect so the padding edges and
        // border are clickable too, not just the content.
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

    /// Project name, identity badges, the running/total health pill, and a
    /// collapse/expand chevron. Tapping the header toggles expand.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.body)
                .foregroundStyle(palette.accent)
            Text(project.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if !project.isStored {
                Text("external")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.tagFill, in: Capsule())
                    .foregroundStyle(palette.tagText)
            }
            if hostsDegraded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(
                        "Service discovery may be degraded: a container couldn't be "
                        + "updated (the image may lack /bin/sh). Services addressed by "
                        + "name might not resolve.")
            }
            Spacer(minLength: 0)
            if isActive {
                ProgressView()
                    .controlSize(.small)
            }
            Text("\(project.runningCount)/\(project.totalCount)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(healthColor.opacity(0.18), in: Capsule())
                .foregroundStyle(healthColor)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 0 : -90))
        }
    }

    /// The single-line summary of services shown when collapsed. Each chip is
    /// tinted by its service status; a trailing "+N" chip (shown only on
    /// overflow) expands the card to the full list. One line keeps every card
    /// the same height in the grid regardless of project size - mirroring
    /// `ContainerCard`'s network/port/mount overflow pattern.
    private var chipRow: some View {
        SingleLineFitLayout(spacing: 6, overflow: $chipOverflow) {
            ForEach(project.services) { service in
                serviceChip(service)
            }
            moreChip
        }
    }

    /// One service as a compact chip, colored by status. A created service uses a
    /// tinted capsule (status color); a not-yet-created service (project is down)
    /// uses a dashed outline so an all-down project reads at a glance.
    private func serviceChip(_ service: ComposeServiceStatus) -> some View {
        let color = serviceChipColor(service)
        let created = service.status != nil
        return Text(service.service)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(created ? color.opacity(0.14) : Color.clear, in: Capsule())
            .foregroundStyle(created ? color : Color.secondary.opacity(0.6))
            .overlay {
                if !created {
                    Capsule()
                        .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(dash: [3, 2]))
                }
            }
    }

    /// Status color for a service chip, distinguishing running / failed
    /// (non-zero exit) / exited (clean or unknown exit) / stopping / not-created.
    private func serviceChipColor(_ service: ComposeServiceStatus) -> Color {
        guard let status = service.status else { return .gray }
        switch status {
        case .running: return .green
        case .stopping: return .orange
        case .unknown: return .red
        case .stopped:
            // A non-zero exit code is a failure; a clean (0) or unknown (nil)
            // exit is a neutral "exited" - we can't call an unknown exit a failure.
            if let code = service.exitCode, code != 0 { return .red }
            return .gray
        }
    }

    /// The "+N" overflow chip. `SingleLineFitLayout` reports the hidden count via
    /// `chipOverflow`; this stays a zero-size placeholder when nothing overflows
    /// (the layout parks it offscreen) and becomes an expanding chip otherwise.
    /// Always present as the last subview so the layout's badge slot is stable.
    @ViewBuilder
    private var moreChip: some View {
        if chipOverflow > 0 {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded = true }
            } label: {
                Text("+\(chipOverflow)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.tagFill, in: Capsule())
            }
            .buttonStyle(.borderless)
            .help("Show all \(project.services.count) services")
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Aggregate health of the project, for the header count badge. A failure
    /// (non-zero exit or unknown status) dominates; otherwise the badge reflects
    /// how much of the project is running.
    private var healthColor: Color {
        let services = project.services
        guard !services.isEmpty else { return .gray }
        let hasFailure = services.contains { service in
            guard let status = service.status else { return false }
            if status == .unknown { return true }
            if status == .stopped, let code = service.exitCode, code != 0 { return true }
            return false
        }
        if hasFailure { return .red }
        if project.runningCount == project.totalCount { return .green }
        if project.runningCount > 0 { return .orange }
        return .gray
    }

    /// The full per-service list shown when expanded - the project's current
    /// detail style: shippingbox row, status pill, and a per-service logs button.
    private var serviceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(project.services) { service in
                serviceRow(service)
            }
        }
    }

    private func serviceRow(_ service: ComposeServiceStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox")
                .font(.caption)
                .foregroundStyle(palette.accent.opacity(0.8))
                .frame(width: 16)
            Text(service.service)
                .font(.callout)
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let status = service.status {
                if let id = service.containerID {
                    Button {
                        onServiceLogs(id)
                    } label: {
                        Image(systemName: "text.alignleft")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("View \(service.service) logs")
                }
                StatusBadge(status: status)
            } else {
                Text("not created")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.12), in: Capsule())
            }
        }
    }

    private var actions: some View {
        // Five buttons (Up/Start/Stop/Down/Remove) don't fit a two-column grid at
        // the default window width if each carries an icon *and* a text label. Let
        // the layout engine decide per-card: show icon + label when the card is
        // wide enough, otherwise fall back to icon-only (labels move to tooltips).
        ViewThatFits(in: .horizontal) {
            actionRow(showTitles: true)
            actionRow(showTitles: false)
        }
        .padding(.top, 2)
    }

    private func actionRow(showTitles: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if project.isStored {
                actionButton(
                    "Up", icon: "arrowtriangle.up.fill", tint: .green,
                    help: "Up",
                    showTitle: showTitles,
                    disabled: isActive || project.runningCount == project.totalCount,
                    labelSpacing: 3, action: onUp)
            }
            actionButton(
                "Start", icon: "play.fill", tint: .green,
                help: "Start",
                showTitle: showTitles,
                disabled: isActive || project.stoppedCount == 0,
                labelSpacing: 3, action: onStart)
            actionButton(
                "Stop", icon: "stop.fill", tint: .orange,
                help: "Stop",
                showTitle: showTitles,
                disabled: isActive || project.runningCount == 0, action: onStop)
            actionButton(
                "Down", icon: "arrowtriangle.down.fill", tint: .red,
                help: "Down",
                showTitle: showTitles,
                disabled: isActive || project.isDown, action: onDown)
            if project.isStored {
                actionButton(
                    "Remove", icon: "trash", tint: .red,
                    help: "Remove",
                    showTitle: showTitles,
                    disabled: isActive, action: onRemove)
            }
            Spacer(minLength: 0)
        }
    }

    /// One project action. Built as a `ContainerCard`-style chip - a 24pt-tall
    /// rounded rect (window-background fill + tinted border) with a tinted icon and,
    /// when the card is wide enough, a caption label - so the Compose and Containers
    /// action rows share one height and one chrome. `ViewThatFits` drops the label on
    /// narrow cards; both variants keep the same 16pt inner height + 4pt vertical
    /// padding so the row is always exactly 24pt (a `.bordered` button + external
    /// height frame didn't hold a uniform height across the two variants).
    @ViewBuilder
    private func actionButton(
        _ title: String, icon: String, tint: Color, help: String,
        showTitle: Bool, disabled: Bool, labelSpacing: CGFloat = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            actionLabel(title, icon: icon, tint: tint, showTitle: showTitle, disabled: disabled, labelSpacing: labelSpacing)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }

    @ViewBuilder
    private func actionLabel(
        _ title: String, icon: String, tint: Color, showTitle: Bool, disabled: Bool,
        labelSpacing: CGFloat = 0
    ) -> some View {
        let chrome = RoundedRectangle(cornerRadius: 6)
        if showTitle {
            // Icon set `labelSpacing` from the label (0 by default for a compact
            // read); Up/Start pass a small gap because their triangular glyphs
            // (▲/▶) crowd the text. minWidth gives every action the same width so
            // the row stays even regardless of label length.
            HStack(spacing: labelSpacing) {
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
            // Same 32×16 cell + padding(4) = 40×24 that ContainerCard uses, so an
            // all-icon row is pixel-identical to the Containers tab.
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
