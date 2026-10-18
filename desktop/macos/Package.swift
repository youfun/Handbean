// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Handbean",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "Handbean", targets: ["Handbean"])
    ],
    targets: [
        .target(name: "HandbeanCore"),
        .executableTarget(
            name: "Handbean",
            dependencies: ["HandbeanCore"]
        ),
        .testTarget(
            name: "HandbeanCoreTests",
            dependencies: ["HandbeanCore"]
        ),
    ]
)
