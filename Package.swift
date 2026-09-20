// swift-tools-version:5.9
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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
