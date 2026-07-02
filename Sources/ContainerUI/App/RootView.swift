import SwiftUI

struct RootView: View {
    @Environment(SystemModel.self) private var system
    @Environment(ComposeModel.self) private var composeModel
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
        // Poll Compose only while the system is up. Restarts when `isRunning`
        // flips, so a downed apiserver isn't hammered every 2s with failing
        // list calls that write pollError (the other tabs get this for free by
        // living inside `detail`, which is itself gated on `isRunning`).
        .task(id: system.isRunning) {
            guard system.isRunning else { return }
            await composeModel.startPolling()
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

