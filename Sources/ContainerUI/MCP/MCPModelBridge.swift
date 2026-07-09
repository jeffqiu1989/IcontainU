import Foundation

struct MCPModelBridge: @unchecked Sendable {
    let containers: ContainersModel
    let images: ImagesModel
    let machines: MachinesModel
    let volumes: VolumesModel
    let networks: NetworksModel
    let compose: ComposeModel
    let system: SystemModel
    /// Server bind address snapshot at start. Changing bind restarts the server,
    /// which rebuilds the bridge, so this stays current. Tools use `isRemote` to
    /// gate host-path bind mounts: a remote-exposed server must not let a client
    /// mount arbitrary host directories into a container.
    let bindAddress: String

    /// True when the server is reachable from the network (0.0.0.0), i.e. not
    /// just localhost. Bind mounts are restricted in this mode.
    var isRemote: Bool { bindAddress == "0.0.0.0" }
}
