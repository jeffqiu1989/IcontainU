import SwiftUI

/// Shared form controls so every create / add sheet looks the same: a blue
/// outlined action button (Load, Add…) and a blue-bordered white dropdown that
/// replaces the gray native `Picker` bezel.

/// Blue outlined button used for secondary form actions (Load, Add Port…). The
/// primary confirm button stays `.borderedProminent` (filled blue); these are the
/// lighter-weight siblings — white fill, blue border, blue text.
struct BlueOutlineButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(Palette.networks)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 4 : 5)
            .background(
                Palette.networks.opacity(configuration.isPressed ? 0.16 : 0.0),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Palette.networks.opacity(0.55), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension ButtonStyle where Self == BlueOutlineButtonStyle {
    static var blueOutline: BlueOutlineButtonStyle { BlueOutlineButtonStyle() }
    static var blueOutlineCompact: BlueOutlineButtonStyle { BlueOutlineButtonStyle(compact: true) }
}

/// A dropdown that matches the form's blue/white theme instead of the gray native
/// `Picker` bezel. Backed by a `Menu`, so it still gets the native popup list and
/// keyboard support — only the closed-state label is restyled (white fill, blue
/// border, a single chevron on the right).
struct StyledPicker<Value: Hashable>: View {
    @Binding var selection: Value
    /// Selectable entries as (value, title) pairs, in display order.
    let options: [(value: Value, title: String)]
    /// Shown when the current selection matches no option (e.g. an empty volume pick).
    var placeholder: String = "Select…"
    var minWidth: CGFloat?
    var disabled: Bool = false

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? placeholder
    }

    private var showsPlaceholder: Bool {
        options.first { $0.value == selection } == nil
    }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.title) { selection = option.value }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(showsPlaceholder ? Color.secondary : Color.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.networks)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: minWidth, alignment: .leading)
            .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Palette.networks.opacity(disabled ? 0.3 : 0.9), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(disabled)
    }
}
