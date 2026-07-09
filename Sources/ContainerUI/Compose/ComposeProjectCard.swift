import ContainerResource
import SwiftUI

/// A card for one compose project: its services with per-service status, plus
/// Up / Start / Stop / Down / Remove controls. The actions share one bordered,
/// uniform-width button style with a semantic-colored icon, keeping the row
/// visually consistent with the app's other cards.
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
    /// Whether the service list is expanded past the collapsed preview limit.
    @State private var servicesExpanded = false
    /// Max services shown before collapsing into a "+N" badge. Keeps every card
    /// the same height in the grid regardless of project size.
    private static let collapsedServiceLimit = 3

    private var palette: CardPalette { CardPalette(color: Palette.compose) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            serviceList
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.10 : 0.03), radius: hovering ? 5 : 2, y: 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

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
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
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

    /// The service list, collapsed to `collapsedServiceLimit` rows with a "+N"
    /// badge when the project has more. Click the badge to expand/collapse, so
    /// every card stays the same height in the grid (mirrors ContainerCard's
    /// network/port/mount overflow pattern).
    @ViewBuilder
    private var serviceList: some View {
        let services = project.services
        let limit = Self.collapsedServiceLimit
        let visible = servicesExpanded ? services : Array(services.prefix(limit))
        let overflow = services.count - limit
        ForEach(visible) { service in
            serviceRow(service)
        }
        if overflow > 0 {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { servicesExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: servicesExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                    Text(servicesExpanded ? "Show less" : "+\(overflow) more")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(palette.tagFill, in: Capsule())
            }
            .buttonStyle(.borderless)
            .help(servicesExpanded ? "Collapse" : "Show all \(services.count) services")
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
            Spacer()
            if project.isStored {
                actionButton(
                    "Up", icon: "arrowtriangle.up.fill", tint: .green,
                    help: "Up",
                    showTitle: showTitles,
                    disabled: isActive, action: onUp)
            }
            actionButton(
                "Start", icon: "play.fill", tint: .green,
                help: "Start",
                showTitle: showTitles,
                disabled: isActive || project.stoppedCount == 0, action: onStart)
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
        }
    }

    /// One project action: a `.bordered` button with a semantic-colored icon and
    /// neutral label, given a uniform minimum width so the row reads as one set.
    /// Matches the neutral-surface + tinted-icon language used across the app's cards.
    /// When `showTitle` is false the label collapses to icon-only (used by
    /// `ViewThatFits` when the card is too narrow for full labels).
    @ViewBuilder
    private func actionButton(
        _ title: String, icon: String, tint: Color, help: String,
        showTitle: Bool, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label(title, icon: icon, tint: tint, showTitle: showTitle, disabled: disabled)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
        .help(help)
    }

    @ViewBuilder
    private func label(_ title: String, icon: String, tint: Color, showTitle: Bool, disabled: Bool) -> some View {
        let base = Label {
            Text(title)
        } icon: {
            // A displayed tint color isn't dimmed by `.disabled()`, so a disabled
            // icon-only button would still look enabled. Gray the icon ourselves.
            Image(systemName: icon).foregroundStyle(disabled ? Color.secondary : tint)
        }
        .font(.caption)
        if showTitle {
            base.labelStyle(.titleAndIcon)
                .frame(minWidth: 52)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            // Icon-only buttons are cramped at caption size; give them a larger
            // glyph and a comfortable tap target so they don't read as tiny.
            base.labelStyle(.iconOnly)
                .imageScale(.large)
                .frame(minWidth: 34)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}
