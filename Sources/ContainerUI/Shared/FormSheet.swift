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

/// The standard modal form scaffold for every create / add / pull sheet.
///
/// Layout is fixed so all sheets look the same: an icon + title header, a divider,
/// a scrolling left-aligned body, a divider, and a right-aligned footer with the
/// native Cancel / confirm buttons. Content is always leading-aligned — sheets are
/// never centered.
struct FormSheet<Body: View, Footer: View>: View {
    enum Width {
        case narrow
        case wide

        var value: CGFloat {
            switch self {
            case .narrow: 440
            case .wide: 560
            }
        }
    }

    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String?
    var width: Width = .narrow
    var height: CGFloat?
    @ViewBuilder var content: () -> Body
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                footer()
            }
            .padding(16)
        }
        .frame(width: width.value)
        .frame(height: height)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
    }
}

/// A form section with a leading label column. The label sits left of the content
/// (macOS Settings style); an optional trailing accessory (e.g. an "Add" button)
/// rides on the same line as the label.
struct LabeledSection<Content: View, Accessory: View>: View {
    let label: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    /// Shared label-column width so every section's labels line up across the form.
    static var labelWidth: CGFloat { 92 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                if Accessory.self != EmptyView.self {
                    HStack {
                        Spacer(minLength: 0)
                        accessory()
                    }
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension LabeledSection where Accessory == EmptyView {
    init(label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.accessory = { EmptyView() }
        self.content = content
    }
}
