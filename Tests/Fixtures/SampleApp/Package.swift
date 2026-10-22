// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SampleApp",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Sample", targets: ["SampleApp"]),
    ],
    dependencies: [
        .package(path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "SampleApp",
            dependencies: [
                .product(name: "DylCore", package: "dyl-kit"),
                .product(name: "DylUI", package: "dyl-kit"),
                .product(name: "DylUpdates", package: "dyl-kit"),
            ]
        ),
    ]
)
