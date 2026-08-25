// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HoverMac",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "HoverMac",
            path: "Sources/HoverMac",
            linkerSettings: [
                .linkedFramework("CoreMIDI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
