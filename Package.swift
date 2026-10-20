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
        .plugin(name: "LintCommand", targets: ["LintCommand"]),
        .plugin(name: "DevCommand", targets: ["DevCommand"]),
        .plugin(name: "ReleaseCommand", targets: ["ReleaseCommand"]),
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

        // SwiftPM plugins.
        .plugin(name: "DylLintPlugin", capability: .buildTool(), dependencies: ["dyl-lint"]),
        .plugin(
            name: "LintCommand",
            capability: .command(
                intent: .custom(verb: "lint", description: "Run SwiftLint with the shared config, then dyl-lint")
            ),
            dependencies: ["dyl-lint"]
        ),
        .plugin(
            name: "DevCommand",
            capability: .command(
                intent: .custom(verb: "dev", description: "Run devkit (build, relaunch, capture, checks)"),
                permissions: [.writeToPackageDirectory(reason: "devkit writes app builds into build/")]
            ),
            dependencies: ["devkit"]
        ),
        .plugin(
            name: "ReleaseCommand",
            capability: .command(
                intent: .custom(
                    verb: "release", description: "Run release-kit (version, bundle, sign, appcast, check)"),
                permissions: [.writeToPackageDirectory(reason: "release-kit writes bundles and release artifacts")]
            ),
            dependencies: ["release-kit"]
        ),

        .testTarget(name: "DylManifestTests", dependencies: ["DylManifest"]),
        .testTarget(name: "DylLintRulesTests", dependencies: ["DylLintRules"]),
        .testTarget(
            name: "ReleaseKitTests",
            dependencies: ["ReleaseKit", "DylManifest", "DylToolSupport"],
            exclude: ["Fixtures"]
        ),
    ]
)
