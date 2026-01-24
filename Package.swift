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
        .package(url: "https://github.com/swift-libp2p/swift-libp2p.git", from: "0.1.0"),
        .package(url: "https://github.com/swift-libp2p/swift-libp2p-kad-dht.git", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0")
    ],
    targets: [
        .executableTarget(
            name: "FolderSync",
            dependencies: [
                .product(name: "LibP2P", package: "swift-libp2p"),
                .product(name: "LibP2PKadDHT", package: "swift-libp2p-kad-dht"),
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
