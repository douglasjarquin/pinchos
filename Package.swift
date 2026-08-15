// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "pinchos",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "pinchos", targets: ["pinchos"]),
        .library(name: "PinchosCore", targets: ["PinchosCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0")
    ],
    targets: [
        .target(
            name: "PinchosCore",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit")
            ]
        ),
        .executableTarget(
            name: "pinchos",
            dependencies: ["PinchosCore"]
        ),
        .testTarget(
            name: "PinchosCoreTests",
            dependencies: ["PinchosCore"]
        ),
        .testTarget(
            name: "pinchosTests",
            dependencies: ["pinchos"]
        )
    ]
)
