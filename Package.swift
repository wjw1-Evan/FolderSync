// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FolderSync",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FolderSync", targets: ["FolderSync"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0")
    ],
    targets: [
        .executableTarget(
            name: "FolderSync",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FolderSync"
        ),
        .testTarget(
            name: "FolderSyncTests",
            dependencies: ["FolderSync"],
            path: "Tests/FolderSyncTests"
        )
    ]
)
