//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import SwiftUI

/// An outlined (hollow) chip used for tappable data values — IP addresses, port
/// mappings, mount paths. Distinct from the filled tag chips used for image tags.
struct OutlinedChip: ViewModifier {
    let accent: Color
    var truncation: Text.TruncationMode = .middle

    func body(content: Content) -> some View {
        content
            .font(.callout)
            .lineLimit(1)
            .truncationMode(truncation)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 1)
            }
    }
}

extension View {
    func outlinedChip(accent: Color, truncation: Text.TruncationMode = .middle) -> some View {
        modifier(OutlinedChip(accent: accent, truncation: truncation))
    }
}

/// Lays out chips on a single line, fitting as many as possible. Any that don't
/// fit are hidden, and the trailing subview (a "+N" badge) is shown with the
/// overflow count reported back through `overflow`. When everything fits, the
/// badge is collapsed to zero size.
///
/// Subviews must be ordered `[chip0, chip1, …, chipN-1, badge]` — the badge is
/// always the last subview.
struct SingleLineFitLayout: Layout {
    var spacing: CGFloat
    @Binding var overflow: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let r = fit(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        return CGSize(width: r.width, height: r.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard !subviews.isEmpty else { return }
        let offscreen = CGPoint(x: bounds.minX - 10_000, y: bounds.minY)
        let r = fit(subviews: subviews, maxWidth: bounds.width)
        let badgeIndex = subviews.count - 1

        var x = bounds.minX
        for i in r.visible {
            let s = subviews[i].sizeThatFits(.unspecified)
            subviews[i].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
        }

        if r.overflow > 0 {
            let s = subviews[badgeIndex].sizeThatFits(.unspecified)
            subviews[badgeIndex].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(s))
        } else {
            // Park the badge far offscreen (the card clips) so a zero proposal can't
            // leave a stray dot at the origin.
            subviews[badgeIndex].place(at: offscreen, anchor: .topLeading, proposal: .zero)
        }

        // Hidden chips have a non-zero minimum size (padding + border) even when
        // proposed zero, so park them offscreen rather than at the origin.
        for i in r.hidden {
            subviews[i].place(at: offscreen, anchor: .topLeading, proposal: .zero)
        }

        if r.overflow != overflow {
            let value = r.overflow
            DispatchQueue.main.async { overflow = value }
        }
    }

    private struct FitResult {
        var visible: [Int]
        var hidden: [Int]
        var overflow: Int
        var width: CGFloat
        var height: CGFloat
    }

    private func fit(subviews: Subviews, maxWidth: CGFloat) -> FitResult {
        let chipCount = subviews.count - 1
        guard chipCount > 0 else { return FitResult(visible: [], hidden: [], overflow: 0, width: 0, height: 0) }

        let badgeSize = subviews[chipCount].sizeThatFits(.unspecified)
        let sizes = (0..<chipCount).map { subviews[$0].sizeThatFits(.unspecified) }
        let height = max(sizes.map(\.height).max() ?? 0, badgeSize.height)

        // First, see if every chip fits with no badge.
        var x: CGFloat = 0
        var fitsAll = true
        for (i, s) in sizes.enumerated() {
            x += (i == 0 ? 0 : spacing) + s.width
            if x > maxWidth {
                fitsAll = false
                break
            }
        }
        if fitsAll {
            return FitResult(visible: Array(0..<chipCount), hidden: [], overflow: 0, width: x, height: height)
        }

        // Otherwise reserve room for the badge and fit what we can.
        let reserve = badgeSize.width + spacing
        var visible: [Int] = []
        x = 0
        for i in 0..<chipCount {
            let add = (visible.isEmpty ? 0 : spacing) + sizes[i].width
            guard x + add + reserve <= maxWidth else { break }
            x += add
            visible.append(i)
        }
        let hidden = Array(visible.count..<chipCount)
        return FitResult(
            visible: visible, hidden: hidden, overflow: chipCount - visible.count,
            width: x + reserve, height: height)
    }
}

/// A flow layout that wraps subviews onto multiple lines. Used for chip rows that
/// should show every item (the expanded state) and for image tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, maxWidth: maxWidth)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.reduce(0) { max($0, $1.maxX) }
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = layout(subviews: subviews, maxWidth: bounds.width)
        for row in rows {
            for item in row.items {
                let point = CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y)
                subviews[item.index].place(at: point, proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat
        var maxX: CGFloat
        var items: [Item]
    }

    private struct Item {
        var index: Int
        var x: CGFloat
        var size: CGSize
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var items: [Item] = []

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !items.isEmpty, x + size.width > maxWidth {
                rows.append(Row(y: y, height: rowHeight, maxX: x - spacing, items: items))
                items = []
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            items.append(Item(index: index, x: x, size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if !items.isEmpty {
            rows.append(Row(y: y, height: rowHeight, maxX: x - spacing, items: items))
        }
        return rows
    }
}
