// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KoalaSignagePlayer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "koala-signage-player", targets: ["KoalaSignagePlayer"])
    ],
    targets: [
        .executableTarget(name: "KoalaSignagePlayer"),
        .testTarget(
            name: "KoalaSignagePlayerTests",
            dependencies: ["KoalaSignagePlayer"]
        )
    ]
)
