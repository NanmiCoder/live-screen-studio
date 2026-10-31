// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveZoom",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ZoomCore"),
        .executableTarget(
            name: "LiveZoom",
            dependencies: ["ZoomCore"],
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        .testTarget(name: "ZoomCoreTests", dependencies: ["ZoomCore"]),
    ],
    swiftLanguageModes: [.v5]
)
