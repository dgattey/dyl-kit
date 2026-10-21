// swift-tools-version: 6.0
import PackageDescription

let dylCore: Target.Dependency = .product(name: "DylCore", package: "DylKit")
let dylUI: Target.Dependency = .product(name: "DylUI", package: "DylKit")

let package = Package(
    name: "SconeKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SconeDomain", targets: ["SconeDomain"]),
        .library(name: "SonosProtocolBoundary", targets: ["SonosProtocolBoundary"]),
        .library(name: "SpotifyBridge", targets: ["SpotifyBridge"]),
        .library(name: "SconeStore", targets: ["SconeStore"]),
        .library(name: "SconeUI", targets: ["SconeUI"]),
        .executable(name: "Sconeos", targets: ["SconeosApp"]),
    ],
    dependencies: [
        .package(path: "Packages/DylKit"),
    ],
    targets: [
        .target(name: "SconeDomain"),
        .target(name: "SonosProtocolBoundary", dependencies: ["SconeDomain", dylCore]),
        .target(name: "SpotifyBridge", dependencies: ["SconeDomain", dylCore]),
        .target(name: "SconeStore", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge"]),
        .target(name: "SconeUI", dependencies: ["SconeStore", "SconeDomain", "SpotifyBridge", dylCore, dylUI]),
        // release-kit's bundler adds the @executable_path/../Frameworks rpath for the embedded Sparkle.framework.
        .executableTarget(
            name: "SconeosApp",
            dependencies: [
                "SconeUI",
                "SconeStore",
                "SconeDomain",
                "SpotifyBridge",
                dylUI,
                .product(name: "DylUpdates", package: "DylKit"),
            ]
        ),
        .testTarget(name: "SconeKitTests", dependencies: ["SconeDomain", "SonosProtocolBoundary", "SpotifyBridge", "SconeStore"]),
    ]
)
