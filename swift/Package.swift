// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ailbum-swift",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "AilbumCore",
            resources: [.copy("Resources/schema.sql")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ailbum-swift",
            dependencies: ["AilbumCore"]
        ),
        .executableTarget(
            name: "AilbumApp",
            dependencies: ["AilbumCore"]
        ),
        .testTarget(
            name: "AilbumCoreTests",
            dependencies: ["AilbumCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
