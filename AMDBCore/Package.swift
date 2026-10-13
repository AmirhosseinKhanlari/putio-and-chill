// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AMDBCore",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AMDBCore", targets: ["AMDBCore"]),
        .library(name: "AMDBKit", targets: ["AMDBKit"]),
    ],
    targets: [
        .target(name: "AMDBCore"),
        .target(name: "AMDBKit", dependencies: ["AMDBCore"]),
        .executableTarget(name: "amdb-spike", dependencies: ["AMDBCore"]),
        .testTarget(name: "AMDBCoreTests", dependencies: ["AMDBCore"]),
        .testTarget(name: "AMDBKitTests", dependencies: ["AMDBKit"]),
    ]
)
