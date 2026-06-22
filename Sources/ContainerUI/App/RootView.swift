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
