// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Announcer",
    platforms: [
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "Announcer",
            path: "Sources/Announcer"
        )
    ]
)
