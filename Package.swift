// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WeChatStorage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WeChatStorage", targets: ["WeChatStorageApp"]),
        .library(name: "WeChatStorageCore", targets: ["WeChatStorageCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "WeChatStorageCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "WeChatStorageApp", dependencies: ["WeChatStorageCore"]),
        .testTarget(name: "WeChatStorageCoreTests", dependencies: ["WeChatStorageCore", "CSQLite"]),
        .testTarget(name: "WeChatStorageAppTests", dependencies: ["WeChatStorageApp", "WeChatStorageCore"])
    ]
)
