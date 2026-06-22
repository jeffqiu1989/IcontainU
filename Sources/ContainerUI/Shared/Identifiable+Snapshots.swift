import ContainerResource
import MachineAPIClient

// `ContainerResource.ImageResource` collides with `DeveloperToolsSupport.ImageResource`
// (re-exported by SwiftUI). Alias it so views can refer to the container image type
// unambiguously.
typealias ContainerImage = ContainerResource.ImageResource

// These snapshot types already expose a stable `id: String`, but neither declares
// `Identifiable`. SwiftUI's `Table`/`selection` require it, so conform here.
// (ImageResource already conforms via its ManagedResource conformance.)
extension ContainerSnapshot: @retroactive Identifiable {}
extension MachineSnapshot: @retroactive Identifiable {}

extension ImageResource {
    /// Total on-disk size across all platform variants, for list display.
    var totalSize: Int64 {
        variants.reduce(0) { $0 + $1.size }
    }
}
