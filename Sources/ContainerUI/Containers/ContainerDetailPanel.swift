import ContainerResource
import SwiftUI

/// Logs-only viewer for a single container. A compact header (name / status /
/// close) sits above a full-height log viewer.
struct ContainerDetailPanel: View {
    let container: ContainerSnapshot
    let onClose: () -> Void

    private var palette: CardPalette { CardPalette(color: Palette.containers) }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            ContainerLogsTab(containerID: container.id)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background)
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Circle().fill(palette.accent).frame(width: 9, height: 9)
            Text(container.id)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            StatusBadge(status: container.status)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(12)
    }
}
