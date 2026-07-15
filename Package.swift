// swift-tools-version: 6.2
import PackageDescription

// Must match the containerization version pinned by the `container` release below
// (the 1.1.0 tag pins 0.35.0).
let scVersion = "0.35.0"

let package = Package(
    name: "IcontainU",
    defaultLocalization: "en",
    platforms: [.macOS("26")],
    products: [
        .executable(name: "IcontainU", targets: ["ContainerUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", exact: "1.1.0"),
        .package(url: "https://github.com/apple/containerization.git", exact: Version(stringLiteral: scVersion)),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        // YAML parsing for the Compose feature. Already present transitively via the
        // `container` package (pinned to 6.2.2 in Package.resolved); declared here as
        // a direct dependency so `import Yams` resolves.
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        // MCP server for remote AI client access
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        // NIO for MCP HTTP server (transitive via swift-sdk, declared here for direct import)
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
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
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/ContainerUI",
            resources: [
                // Localized strings as plain .strings inside per-locale .lproj dirs.
                // SPM preserves the .lproj structure in the resource bundle; the
                // packaging script copies these dirs into the .app's Contents/Resources/
                // so Bundle.main finds them. (swift build does not compile .xcstrings,
                // so we ship .strings directly - also simpler for non-Xcode contributors.)
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"),
            ]
        ),
        .testTarget(
            name: "ContainerUITests",
            dependencies: [
                "ContainerUI"
            ]
        ),
    ]
)
