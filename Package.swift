// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveZoom",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ZoomCore"),
        .target(name: "CursorKit", dependencies: ["ZoomCore"]),
        .executableTarget(
            name: "LiveZoom",
            dependencies: ["ZoomCore", "CursorKit"],
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        .testTarget(name: "ZoomCoreTests", dependencies: ["ZoomCore"]),
        .testTarget(name: "CursorKitTests", dependencies: ["CursorKit"]),
    ],
    swiftLanguageModes: [.v5]
)
