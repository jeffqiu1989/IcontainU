import ContainerResource
import SwiftUI

/// A colorful card for a single network, matching the shared card style.
/// Built-in networks cannot be deleted.
struct NetworkCard: View {
    let network: NetworkResource
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var palette: CardPalette { CardPalette(color: Palette.networks) }

    private var subnetText: String { network.status.ipv4Subnet.description }

    private var modeText: String { network.configuration.mode.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            infoRow(icon: "point.3.connected.trianglepath.dotted", text: "Subnet: \(subnetText)")
            infoRow(icon: "arrow.triangle.branch", text: "Mode: \(modeText)")
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if isSelected {
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                    .fill(palette.accent)
                    .frame(width: 5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(palette.border, lineWidth: isSelected ? 2 : 1)
        }
        .shadow(
            color: .black.opacity(hovering || isSelected ? 0.10 : 0.03),
            radius: hovering || isSelected ? 5 : 2, y: 1
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.body)
                .foregroundStyle(palette.accent)
            Text(network.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if network.isBuiltin {
                Text("built-in")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.tagFill, in: Capsule())
                    .foregroundStyle(palette.tagText)
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .frame(width: 26, height: 16)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.red)
            .disabled(network.isBuiltin)
            .help(network.isBuiltin ? "Built-in networks cannot be deleted" : "Delete")
        }
        .padding(.top, 2)
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(palette.accent.opacity(0.8))
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .foregroundStyle(Color.primary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
