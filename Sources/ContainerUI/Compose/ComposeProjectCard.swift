import ContainerResource
import SwiftUI

/// A card for one compose project: its services with per-service status, plus
/// Up / Down / Remove controls. Mirrors the neutral-surface card style used by
/// NetworkCard / ContainerCard.
struct ComposeProjectCard: View {
    let project: ComposeProjectView
    let isBusy: Bool
    let isUpping: Bool
    /// True when some container in this project couldn't receive its `/etc/hosts`
    /// service-discovery block (e.g. an image without `/bin/sh`).
    let hostsDegraded: Bool
    let onUp: () -> Void
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
            if isUpping {
                ProgressView().controlSize(.small)
            }
            // Up: enabled for stored projects that aren't fully running.
            if project.isStored {
                Button(action: onUp) {
                    Label("Up", systemImage: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Palette.compose)
                .disabled(isBusy || isUpping)
                .help("Create and start the project's services")
            }
            Button(action: onDown) {
                Label("Down", systemImage: "stop.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy || isUpping || project.isDown)
            .help("Stop and delete the project's containers")

            if project.isStored {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .frame(width: 26, height: 16)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
                .disabled(isBusy || isUpping)
                .help("Remove the project and all its resources")
            }
        }
        .padding(.top, 2)
    }
}
