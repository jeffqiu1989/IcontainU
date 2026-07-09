import Foundation

struct MCPModelBridge: @unchecked Sendable {
    let containers: ContainersModel
    let images: ImagesModel
    let machines: MachinesModel
    let volumes: VolumesModel
    let networks: NetworksModel
    let compose: ComposeModel
    let system: SystemModel
}
