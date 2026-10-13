// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AMDBCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AMDBCore", targets: ["AMDBCore"])],
    targets: [
        .target(name: "AMDBCore"),
        .testTarget(name: "AMDBCoreTests", dependencies: ["AMDBCore"]),
    ]
)
