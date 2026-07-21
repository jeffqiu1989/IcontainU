import Logging
import SwiftUI

@main
struct ContainerUIApp: App {
    @State private var systemModel = SystemModel()
    // Owned at app scope so their state (in-flight progress, errors) survives tab
    // switches — a tab's view is torn down when you navigate away, but the model
    // must not be, or a running pull/create and its progress would vanish.
    @State private var containersModel = ContainersModel()
    @State private var composeModel = ComposeModel()
    @State private var imagesModel = ImagesModel()
    @State private var machinesModel = MachinesModel()
    @State private var networksModel = NetworksModel()
    @State private var volumesModel = VolumesModel()
    @State private var buildsModel = BuildsModel()

    @State private var mcpSettings = MCPSettings()
    @State private var mcpRequestLog = MCPRequestLog()
    @State private var mcpServerManager: MCPServerManager?

    init() {
        // Route swift-log to stderr so `swift run IcontainU` shows the full
        // create pipeline (every flag passed to containerConfigFromFlags) in the
        // console — invaluable for spotting a misparsed argument. Debug level so
        // nothing is filtered out during development.
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .debug
            return handler
        }

        // When launched as a bare SPM executable (not a .app bundle), the process
        // defaults to a non-regular activation policy and the window never comes
        // to the foreground. Promote it so the UI appears.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("IcontainU") {
            RootView()
                .environment(systemModel)
                .environment(containersModel)
                .environment(composeModel)
                .environment(imagesModel)
                .environment(machinesModel)
                .environment(networksModel)
                .environment(volumesModel)
                .environment(buildsModel)
                .environment(mcpServerManager)
                .frame(minWidth: 900, minHeight: 540)
                .onAppear {
                    guard mcpServerManager == nil else { return }
                    let manager = MCPServerManager(
                        settings: mcpSettings,
                        requestLog: mcpRequestLog,
                        containersModel: containersModel,
                        imagesModel: imagesModel,
                        machinesModel: machinesModel,
                        volumesModel: volumesModel,
                        networksModel: networksModel,
                        composeModel: composeModel,
                        systemModel: systemModel
                    )
                    mcpServerManager = manager
                    if mcpSettings.isEnabled {
                        Task { try? await manager.start() }
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 780)
    }
}
