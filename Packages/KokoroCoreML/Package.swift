// swift-tools-version: 5.9
// A trimmed local snapshot of https://github.com/mattmireles/kokoro-coreml.
// See VENDORED.md for the revision and what was left out.

import PackageDescription

let package = Package(
    name: "KokoroCoreML",
    platforms: [
        .macOS("15.0"),
        .iOS("18.0"),
    ],
    products: [
        .library(name: "KokoroTTS", targets: ["KokoroTTS"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/mattmireles/MisakiSwift",
            revision: "3a27756a780fc138e328a96e533fb440a3419d5b"
        ),
    ],
    targets: [
        .target(
            name: "KokoroTTS",
            dependencies: [
                "KokoroPipeline",
                .product(name: "MisakiSwift", package: "MisakiSwift"),
            ],
            path: "swift-tts/Sources/KokoroTTS",
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "KokoroPipeline",
            path: "swift/Sources/KokoroPipeline"
        ),
    ]
)
