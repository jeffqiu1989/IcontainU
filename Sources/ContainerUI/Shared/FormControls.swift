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

/// Measures a field's rendered height so a floating suggestion list can be offset
/// to sit exactly below it (rather than relying on a magic constant).
struct FieldHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 22
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A text field with an inline autocomplete list, matching the Image field: type a
/// value freely, or pick one of the known `options` from a list that floats just
/// below the field. The list is an overlay (offset by the measured field height),
/// so it never displaces sibling rows — but the *caller* must raise the enclosing
/// row/section `zIndex` while `onActiveChange(true)` so the list paints above later
/// content. Typing a value not in `options` is allowed (e.g. a new volume name,
/// auto-created by the engine on run). No dropdown chevron — it behaves like a
/// plain text field, with suggestions appearing only on focus.
struct AutocompleteField: View {
    @Binding var text: String
    /// Known values offered as suggestions, in display order.
    let options: [String]
    var placeholder: String = ""
    /// Optional leading SF Symbol shown on each suggestion row.
    var icon: String? = nil
    var iconColor: Color = Palette.networks
    /// Called when the suggestion list appears/disappears, so the caller can raise
    /// this row's `zIndex` to keep the floating list above neighbouring rows.
    var onActiveChange: (Bool) -> Void = { _ in }

    @FocusState private var focused: Bool
    @State private var fieldHeight: CGFloat = FieldHeightKey.defaultValue
    @State private var highlighted = 0

    /// Max rows shown at once; the field still accepts values beyond these.
    private static let maxRows = 6

    private var matches: [String] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        let base = query.isEmpty ? options : options.filter { $0.lowercased().hasPrefix(query) }
        return Array(base.prefix(Self.maxRows))
    }

    private var showSuggestions: Bool { focused && !matches.isEmpty }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.return) { commit() }
            .onKeyPress(.escape) { focused = false; return .handled }
            .onChange(of: text) { _, _ in highlighted = 0 }
            .onChange(of: focused) { _, _ in highlighted = 0 }
            .onChange(of: showSuggestions) { _, visible in onActiveChange(visible) }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: FieldHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(FieldHeightKey.self) { fieldHeight = $0 }
            // The list floats below the field (offset by its height) so it overlays
            // following rows instead of pushing them down, and never covers the
            // field itself — the field stays editable while suggestions show.
            .overlay(alignment: .topLeading) {
                if showSuggestions {
                    suggestionList.offset(y: fieldHeight + 4)
                }
            }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element) { index, option in
                Button {
                    select(option)
                } label: {
                    HStack(spacing: 6) {
                        if let icon {
                            Image(systemName: icon).font(.caption).foregroundStyle(iconColor)
                        }
                        Text(option).font(.callout).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == highlighted ? Palette.networks.opacity(0.14) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index != matches.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Palette.networks.opacity(0.5), lineWidth: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func select(_ option: String) {
        text = option
        focused = false
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard showSuggestions else { return .ignored }
        highlighted = max(0, min(matches.count - 1, highlighted + delta))
        return .handled
    }

    private func commit() -> KeyPress.Result {
        if showSuggestions, matches.indices.contains(highlighted) {
            select(matches[highlighted])
            return .handled
        }
        focused = false
        return .ignored
    }
}

/// A compact two-or-more segment toggle styled to match the form's rounded-border
/// text fields. The native `.segmented` picker insets its bezel a few points
/// inside the frame, so its border never lines up with an adjacent `TextField`;
/// this control draws its border flush at the frame edge, so it left-aligns with
/// the text fields above and below it. Generic over the tag value; each segment
/// carries either a short text label or an SF Symbol.
struct SegmentedToggle<Value: Hashable>: View {
    @Binding var selection: Value
    let segments: [Segment]
    var accent: Color = Palette.networks

    struct Segment {
        let value: Value
        var text: String?
        var systemImage: String?

        init(_ value: Value, text: String? = nil, systemImage: String? = nil) {
            self.value = value
            self.text = text
            self.systemImage = systemImage
        }
    }

    /// Matches the rounded-border text field's bezel so the two read as one family.
    private static var cornerRadius: CGFloat { 5 }
    /// Matches a regular-size rounded-border text field's intrinsic height.
    private static var height: CGFloat { 21 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                let isSelected = segment.value == selection
                Button {
                    selection = segment.value
                } label: {
                    label(for: segment, selected: isSelected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(isSelected ? accent.opacity(0.16) : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index != segments.count - 1 {
                    Divider().overlay(Color(.separatorColor))
                }
            }
        }
        .frame(height: Self.height)
        .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color(.separatorColor), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    @ViewBuilder
    private func label(for segment: Segment, selected: Bool) -> some View {
        let tint = selected ? accent : Color.secondary
        if let text = segment.text {
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
        } else if let symbol = segment.systemImage {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
        }
    }
}
