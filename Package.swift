// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Jot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Jot",
            path: "Sources/Jot"
        ),
        .testTarget(
            name: "JotTests",
            dependencies: ["Jot"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
