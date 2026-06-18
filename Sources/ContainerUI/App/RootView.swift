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

struct RootView: View {
    @Environment(SystemModel.self) private var system
    @State private var selection: SidebarItem = .containers

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        SystemStatusBar()
                    }
                    .background(.bar)
                }
        } detail: {
            detail
                .disabled(!system.isRunning)
                .overlay {
                    if !system.isRunning {
                        SystemUnavailableOverlay()
                    }
                }
        }
        .task {
            await system.startMonitoring()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .containers:
            ContainersView()
        case .machines:
            MachinesView()
        case .images:
            ImagesView()
        case .volumes:
            VolumesView()
        case .networks:
            NetworksView()
        case .system:
            SystemView()
        case .registries:
            RegistriesView()
        }
    }
}

/// Placeholder shown for resource domains that are on the roadmap but not yet built.
struct ComingSoonView: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text("Coming soon.")
        }
    }
}
