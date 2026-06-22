import ContainerResource
import SwiftUI

/// A colored status pill shared by both containers and machines, since both
/// report their state via `RuntimeStatus`.
struct StatusBadge: View {
    let status: RuntimeStatus

    private var color: Color {
        switch status {
        case .running: .green
        case .stopped: .gray
        case .stopping: .orange
        case .unknown: .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(status.rawValue.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}
