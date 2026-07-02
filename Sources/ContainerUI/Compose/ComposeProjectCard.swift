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

    private var palette: CardPalette { CardPalette(color: Palette.compose) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(project.services) { service in
                serviceRow(service)
            }
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

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            if project.isStored {
                actionButton(
                    "Up", icon: "arrow.up.circle.fill", tint: .green,
                    help: "Create and start all services",
                    disabled: isActive, action: onUp)
            }
            actionButton(
                "Start", icon: "play.fill", tint: .green,
                help: "Start stopped containers",
                disabled: isActive || project.stoppedCount == 0, action: onStart)
            actionButton(
                "Stop", icon: "stop.fill", tint: .orange,
                help: "Stop running containers without deleting them",
                disabled: isActive || project.runningCount == 0, action: onStop)
            actionButton(
                "Down", icon: "arrow.down.circle.fill", tint: .red,
                help: "Stop and delete all containers",
                disabled: isActive || project.isDown, action: onDown)
            if project.isStored {
                actionButton(
                    "Remove", icon: "trash", tint: .red,
                    help: "Remove the project and all its resources",
                    disabled: isActive, action: onRemove)
            }
        }
        .padding(.top, 2)
    }

    /// One project action: a `.bordered` button with a semantic-colored icon and
    /// neutral label, given a uniform minimum width so the row reads as one set.
    /// Matches the neutral-surface + tinted-icon language used across the app's cards.
    private func actionButton(
        _ title: String, icon: String, tint: Color, help: String,
        disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            .font(.caption)
            .frame(minWidth: 52)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
        .help(help)
    }
}
