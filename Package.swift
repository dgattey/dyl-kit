// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DylKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DylCore", targets: ["DylCore"]),
        .library(name: "DylManifest", targets: ["DylManifest"]),
        .executable(name: "dyl-lint", targets: ["dyl-lint"]),
        .executable(name: "devkit", targets: ["devkit"]),
        .executable(name: "release-kit", targets: ["release-kit"]),
        .plugin(name: "DylLintPlugin", targets: ["DylLintPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "602.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Runtime helpers shared by the app and the tools.
        .target(name: "DylCore"),

        // Host tooling.
        .target(name: "DylManifest"),
        .target(name: "DylToolSupport", dependencies: ["DylManifest"]),
        .target(
            name: "DylLintRules",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "dyl-lint",
            dependencies: [
                "DylLintRules",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "ReleaseKit", dependencies: ["DylCore", "DylManifest", "DylToolSupport"]),
        .executableTarget(
            name: "release-kit",
            dependencies: [
                "ReleaseKit",
                "DylToolSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "DevKitCore", dependencies: ["DylLintRules", "DylManifest", "DylToolSupport", "ReleaseKit"]),
        .executableTarget(
            name: "devkit",
            dependencies: [
                "DevKitCore",
                "DylToolSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // Runs dyl-lint during app builds.
        .plugin(name: "DylLintPlugin", capability: .buildTool(), dependencies: ["dyl-lint"]),

        .testTarget(name: "DylManifestTests", dependencies: ["DylManifest"]),
        .testTarget(name: "DylLintRulesTests", dependencies: ["DylLintRules"]),
        .testTarget(
            name: "ReleaseKitTests",
            dependencies: ["ReleaseKit", "DylManifest", "DylToolSupport"],
            exclude: ["Fixtures"]
        ),
    ]
)
