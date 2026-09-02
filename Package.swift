// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nota",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nota",
            path: "Sources/Nota"
        ),
        .testTarget(
            name: "NotaTests",
            dependencies: ["Nota"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
