// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Celsius",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Celsius", targets: ["Celsius"]),
    ],
    targets: [
        .target(name: "CelsiusCore"),
        .executableTarget(name: "Celsius", dependencies: ["CelsiusCore"]),
        .testTarget(
            name: "CelsiusCoreTests",
            dependencies: ["CelsiusCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
