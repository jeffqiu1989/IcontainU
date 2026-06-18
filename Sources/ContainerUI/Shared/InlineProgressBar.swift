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

/// The single inline progress strip used by every long operation (pull / create).
/// Pinned to the top of a view, deliberately slim: one caption line (phase +
/// bytes/percent) over a 4pt rounded bar, minimal padding, no filled background,
/// a hairline divider beneath. Replaces the three near-duplicate progress bars.
///
/// Determinate progress eases over ~0.3s so the monotonic forward movement of
/// `OperationProgress.displayedFraction` glides instead of stepping.
struct InlineProgressBar: View {
    let progress: OperationProgress
    var accent: Color = .accentColor

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private var metrics: String? {
        guard progress.isDeterminate else { return nil }
        let done = Self.byteFormatter.string(fromByteCount: progress.currentSize)
        let total = Self.byteFormatter.string(fromByteCount: progress.totalSize)
        let percent = Int((progress.displayedFraction * 100).rounded())
        return "\(done) / \(total) · \(percent)%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(progress.phaseLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let metrics {
                    Text(metrics)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            bar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var bar: some View {
        if progress.isDeterminate {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(accent)
                        .frame(width: max(0, geo.size.width * progress.displayedFraction))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.3), value: progress.displayedFraction)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(accent)
        }
    }
}
