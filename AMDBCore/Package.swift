// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AMDBCore",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "AMDBCore", targets: ["AMDBCore"])],
    targets: [
        .target(name: "AMDBCore"),
        .executableTarget(name: "amdb-spike", dependencies: ["AMDBCore"]),
        .testTarget(name: "AMDBCoreTests", dependencies: ["AMDBCore"]),
    ]
)
