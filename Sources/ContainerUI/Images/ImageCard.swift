import ContainerResource
import SwiftUI

/// A card for a single repository. Collapsed (the default) it shows the
/// repository name and a wrapping row of its tag chips, so the whole list of
/// images is scannable at a glance and every card is the same short height.
/// Expanding the card reveals per-tag details (architecture, digest, size) and
/// the delete controls — needed only occasionally, e.g. before removing a tag.
struct ImageRepoCard: View {
    let group: ImageRepoGroup
    let onDelete: (ContainerImage) -> Void

    @State private var hovering = false
    @State private var expanded = false

    private var palette: CardPalette {
        CardPalette(seed: group.repository)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header
                tagChips
            }
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            }
            if expanded {
                Divider()
                detailList
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Palette.cardBorder, lineWidth: expanded ? 2 : 1)
        }
        .shadow(
            color: .black.opacity(expanded ? 0.24 : (hovering ? 0.10 : 0.03)),
            radius: expanded ? 12 : (hovering ? 5 : 2), y: expanded ? 3 : 1
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: expanded)
    }

    /// Repository name, tag count, and the collapse/expand chevron.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "opticaldiscdrive")
                .font(.body)
                .foregroundStyle(palette.accent)
            Text(group.repository)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text("\(group.tags.count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(palette.tagFill, in: Capsule())
                .foregroundStyle(palette.tagText)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 0 : -90))
        }
    }

    /// The wrapping row of tag chips shown whether or not the card is expanded.
    private var tagChips: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(group.tags) { tag in
                Text(tag.tag)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.tagFill, in: Capsule())
                    .foregroundStyle(palette.tagText)
                    .lineLimit(1)
            }
        }
    }

    private var detailList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(group.tags) { tag in
                TagDetailRow(tag: tag, palette: palette, onDelete: onDelete)
                if tag.id != group.tags.last?.id {
                    Divider().opacity(0.5)
                }
            }
        }
    }
}

/// A single tag's details: tag chip, default architecture, digest, size, delete,
/// and an optional expander for the remaining architectures.
private struct TagDetailRow: View {
    let tag: ImageTagRow
    let palette: CardPalette
    let onDelete: (ContainerImage) -> Void

    @State private var showArches = false

    private var sizeText: String {
        tag.totalSize > 0
            ? ByteCountFormatter.string(fromByteCount: tag.totalSize, countStyle: .file)
            : "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(tag.tag)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.tagFill, in: Capsule())
                    .foregroundStyle(palette.tagText)
                    .lineLimit(1)
                if let current = tag.current {
                    Text(current.arch)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.primary.opacity(0.85))
                    Text(current.shortDigest)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.primary.opacity(0.6))
                }
                Spacer(minLength: 0)
                Text(sizeText)
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.7))
                Button {
                    onDelete(tag.image)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Delete \(tag.tag)")
            }

            if !tag.others.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { showArches.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showArches ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("\(tag.others.count) more architectures")
                            .font(.caption)
                    }
                    .foregroundStyle(palette.accent)
                }
                .buttonStyle(.borderless)

                if showArches {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(tag.others) { entry in
                            HStack(spacing: 8) {
                                Text(entry.arch)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Color.primary.opacity(0.85))
                                    .frame(width: 80, alignment: .leading)
                                Text(entry.shortDigest)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Color.primary.opacity(0.6))
                                Spacer(minLength: 0)
                                Text(entry.size > 0 ? ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file) : "—")
                                    .font(.caption2)
                                    .foregroundStyle(Color.primary.opacity(0.7))
                            }
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.top, 2)
                }
            }
        }
    }
}
