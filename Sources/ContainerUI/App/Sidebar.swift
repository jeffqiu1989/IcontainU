import SwiftUI

/// Every top-level destination in the sidebar. Adding a new resource domain is a
/// single case here plus a folder under Sources/ContainerUI and a branch in
/// RootView's detail switch — the grouping below stays untouched.
enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    // WORKLOADS
    case containers
    case compose
    case machines
    // RESOURCES
    case images
    case volumes
    case networks
    // REGISTRY
    case registries
    // bottom
    case mcp
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .compose: "Compose"
        case .machines: "Machines"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .registries: "Registries"
        case .mcp: "MCP"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .containers: "shippingbox"
        case .compose: "square.stack.3d.up"
        case .machines: "server.rack"
        case .images: "opticaldiscdrive"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .registries: "key"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .system: "gearshape"
        }
    }

    /// Semantic color shared with the matching cards, so the same hue means the
    /// same kind of thing throughout the app.
    var color: Color {
        switch self {
        case .containers: Palette.containers
        case .compose: Palette.compose
        case .machines: Palette.machines
        case .images: Palette.images
        case .volumes: Palette.volumes
        case .networks: Palette.networks
        case .registries: Palette.registries
        case .mcp: .purple
        case .system: Palette.system
        }
    }

    /// Whether the domain is implemented. Unimplemented items render grayed out
    /// so the product roadmap is visible in the sidebar.
    var isAvailable: Bool {
        true
    }
}

struct Sidebar: View {
    @Binding var selection: SidebarItem

    var body: some View {
        List(selection: $selection) {
            Section("Workloads") {
                row(.containers)
                row(.compose)
                row(.machines)
            }
            Section("Resources") {
                row(.images)
                row(.volumes)
                row(.networks)
            }
            Section("Registry") {
                row(.registries)
            }
            Section("System") {
                row(.mcp)
                row(.system)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .foregroundStyle(item.isAvailable ? .primary : .tertiary)
            .tag(item)
    }
}
