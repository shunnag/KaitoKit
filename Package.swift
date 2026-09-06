// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KaitoKit",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "KaitoKit", targets: ["KaitoKit"]),
        .library(name: "KaitoKitCompat", targets: ["KaitoKitCompat"]),
        .library(
            name: "KaitoKitDynamic",
            type: .dynamic,
            targets: ["KaitoKit", "KaitoKitCompat"]
        ),
        .executable(name: "kaito", targets: ["kaito"])
    ],
    targets: [
        .systemLibrary(
            name: "CBzip2",
            path: "Sources/CBzip2"
        ),
        .target(
            name: "KaitoKit",
            dependencies: ["CBzip2"],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "KaitoKitCompat",
            dependencies: ["KaitoKit"]
        ),
        .executableTarget(
            name: "kaito",
            dependencies: ["KaitoKit"]
        ),
        .testTarget(
            name: "KaitoKitTests",
            dependencies: ["KaitoKit"]
        ),
        .testTarget(
            name: "KaitoKitCompatTests",
            dependencies: ["KaitoKitCompat", "KaitoKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
