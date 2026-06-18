// swift-tools-version: 6.2
//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import PackageDescription

// Must match the containerization version pinned by the `container` release below
// (the 1.0.0 tag pins 0.33.3).
let scVersion = "0.33.3"

let package = Package(
    name: "container-ui",
    platforms: [.macOS("15")],
    products: [
        .executable(name: "container-ui", targets: ["ContainerUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", exact: "1.0.0"),
        .package(url: "https://github.com/apple/containerization.git", exact: Version(stringLiteral: scVersion)),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ContainerUI",
            dependencies: [
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "MachineAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                // product `ContainerImagesService` re-exports the `ContainerImagesServiceClient` target.
                .product(name: "ContainerImagesService", package: "container"),
                .product(name: "TerminalProgress", package: "container"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ContainerUI"
        ),
        .testTarget(
            name: "ContainerUITests",
            dependencies: [
                "ContainerUI"
            ]
        ),
    ]
)
