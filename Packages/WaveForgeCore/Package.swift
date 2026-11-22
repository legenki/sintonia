// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WaveForgeCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "SynthCore", targets: ["SynthCore"]),
        .library(name: "PresetKit", targets: ["PresetKit"]),
        .library(name: "WaveForgeExport", targets: ["WaveForgeExport"]),
    ],
    targets: [
        .target(
            name: "SynthCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "PresetKit",
            dependencies: ["SynthCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "WaveForgeExport",
            dependencies: ["SynthCore", "PresetKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SynthCoreTests",
            dependencies: ["SynthCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "PresetKitTests",
            dependencies: ["PresetKit", "SynthCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "WaveForgeExportTests",
            dependencies: ["WaveForgeExport", "SynthCore", "PresetKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
