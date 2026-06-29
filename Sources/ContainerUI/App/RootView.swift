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
            if system.isRunning {
                detail
            } else {
                SystemUnavailableOverlay()
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
        case .compose:
            ComposeView()
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

