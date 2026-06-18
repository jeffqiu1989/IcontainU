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

import ContainerResource
import SwiftUI

/// A colorful card for a single volume, matching the shared card style.
struct VolumeCard: View {
    let volume: VolumeConfiguration
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var palette: CardPalette { CardPalette(color: Palette.volumes) }

    private var sizeText: String? {
        volume.sizeInBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            infoRow(icon: "internaldrive", text: "Driver: \(volume.driver)")
            infoRow(icon: "doc", text: sizeText ?? "Size unknown", secondary: sizeText == nil)
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
            Image(systemName: "externaldrive")
                .font(.body)
                .foregroundStyle(palette.accent)
            Text(volume.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(volume.isAnonymous ? "anonymous" : "named")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(palette.tagFill, in: Capsule())
                .foregroundStyle(palette.tagText)
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
            .help("Delete")
        }
        .padding(.top, 2)
    }

    private func infoRow(icon: String, text: String, secondary: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(palette.accent.opacity(0.8))
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .foregroundStyle(secondary ? Color.secondary.opacity(0.7) : Color.primary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
