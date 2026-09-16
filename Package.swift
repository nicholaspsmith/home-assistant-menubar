// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Homestead",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Homestead", targets: ["Homestead"]),
        .library(name: "HomesteadCore", targets: ["HomesteadCore"]),
    ],
    dependencies: [
        .package(path: "../StatusItemKit"),
    ],
    targets: [
        .target(name: "HomesteadCore"),
        .executableTarget(
            name: "Homestead",
            dependencies: [
                "HomesteadCore",
                .product(name: "StatusItemKit", package: "StatusItemKit"),
            ]
        ),
        .testTarget(name: "HomesteadCoreTests", dependencies: ["HomesteadCore"]),
    ]
)
