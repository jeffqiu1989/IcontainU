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

import ContainerResource
import MachineAPIClient

// `ContainerResource.ImageResource` collides with `DeveloperToolsSupport.ImageResource`
// (re-exported by SwiftUI). Alias it so views can refer to the container image type
// unambiguously.
typealias ContainerImage = ContainerResource.ImageResource

// These snapshot types already expose a stable `id: String`, but neither declares
// `Identifiable`. SwiftUI's `Table`/`selection` require it, so conform here.
// (ImageResource already conforms via its ManagedResource conformance.)
extension ContainerSnapshot: Identifiable {}
extension MachineSnapshot: Identifiable {}

extension ImageResource {
    /// Total on-disk size across all platform variants, for list display.
    var totalSize: Int64 {
        variants.reduce(0) { $0 + $1.size }
    }
}
