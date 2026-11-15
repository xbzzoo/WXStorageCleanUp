// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WXStorageCleanUp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WXStorageCleanUp", targets: ["WXStorageCleanUpApp"]),
        .library(name: "WXStorageCleanUpCore", targets: ["WXStorageCleanUpCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "WXStorageCleanUpCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "WXStorageCleanUpApp", dependencies: ["WXStorageCleanUpCore"]),
        .testTarget(name: "WXStorageCleanUpCoreTests", dependencies: ["WXStorageCleanUpCore", "CSQLite"]),
        .testTarget(name: "WXStorageCleanUpAppTests", dependencies: ["WXStorageCleanUpApp", "WXStorageCleanUpCore"])
    ]
)
