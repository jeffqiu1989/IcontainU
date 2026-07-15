import AppKit
import SwiftUI

/// Persistent error strip for a failed operation. Unlike a transient toast, this
/// stays until the user dismisses it (the model's `lastError` is not touched by
/// polling) and offers a copy button — so an error can be read and reported
/// instead of flashing by.
///
/// The strip itself stays slim and fixed-height: title plus up to three lines of
/// detail. Full detail opens in a **popover**, which floats above the layout
/// instead of growing the strip in place — expanding inline pushed the card grid
/// out of view and forced the split view to collapse the sidebar. Full text also
/// always reaches the pasteboard via copy.
struct ErrorBanner: View {
    private let title: String
    private let detail: String
    private let onCopy: () -> Void
    /// When nil, the close button is hidden (read-only banner for panel load
    /// errors that are cleared by their own refresh rather than by the user).
    private let onDismiss: (() -> Void)?

    @State private var showDetail = false

    private static let collapsedLineLimit = 3

    /// Dismissible banner for a failed operation: full detail, copy, and close.
    init(error: OperationError, onCopy: @escaping () -> Void = {}, onDismiss: @escaping () -> Void) {
        self.title = error.title
        self.detail = error.detail
        self.onCopy = onCopy
        self.onDismiss = onDismiss
    }

    /// Read-only banner for a plain message (panel load failures). Copyable but
    /// not dismissible.
    init(message: String, onCopy: @escaping () -> Void = {}) {
        self.title = message
        self.detail = ""
        self.onCopy = onCopy
        self.onDismiss = nil
    }

    private var copyText: String { detail.isEmpty ? title : "\(title)\n\(detail)" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
                if !detail.isEmpty {
                    Text(LocalizedStringKey(detail))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(Self.collapsedLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 2) {
                    Button(action: copy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy error details")

                    if let onDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                    }
                }
                .foregroundStyle(.secondary)
                .font(.callout)

                if isTruncatable {
                    Button("Details") { showDetail = true }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
                            detailPopover
                        }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.05))
        .overlay(alignment: .leading) {
            Rectangle().fill(.red.opacity(0.8)).frame(width: 3)
        }
    }

    /// Full, scrollable, selectable detail — floated in a popover so it never
    /// disturbs the underlying layout.
    private var detailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.weight(.semibold))
            ScrollView {
                Text(detail)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            HStack {
                Spacer()
                Button("Copy", action: copy)
            }
        }
        .padding(14)
        .frame(width: 420)
    }

    /// Whether the detail is long enough to be worth a "Details" popover (the strip
    /// shows at most three lines; assume ~70 chars/line).
    private var isTruncatable: Bool {
        detail.count > Self.collapsedLineLimit * 70 || detail.contains("\n")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        onCopy()
    }
}
