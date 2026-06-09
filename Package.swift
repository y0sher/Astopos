// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Astopos",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Astopos",
            path: "Sources/Astopos",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "AstoposTests",
            dependencies: ["Astopos"],
            path: "Tests/AstoposTests"
        )
    ]
)
