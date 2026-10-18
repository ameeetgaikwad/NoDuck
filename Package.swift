// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoDuck",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "NoDuck",
            path: "Sources/NoDuck",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
            ]
        )
    ]
)
