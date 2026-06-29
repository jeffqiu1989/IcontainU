// swift-tools-version: 6.2
import PackageDescription

// Must match the containerization version pinned by the `container` release below
// (the 1.0.0 tag pins 0.33.3).
let scVersion = "0.33.3"

let package = Package(
    name: "IcontainU",
    platforms: [.macOS("26")],
    products: [
        .executable(name: "IcontainU", targets: ["ContainerUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", exact: "1.0.0"),
        .package(url: "https://github.com/apple/containerization.git", exact: Version(stringLiteral: scVersion)),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        // YAML parsing for the Compose feature. Already present transitively via the
        // `container` package (pinned to 6.2.2 in Package.resolved); declared here as
        // a direct dependency so `import Yams` resolves.
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
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
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "yams"),
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
