// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScanCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"])
    ],
    targets: [
        .target(name: "ScanCore"),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"])
    ]
)
