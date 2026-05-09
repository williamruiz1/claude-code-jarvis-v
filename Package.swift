// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Sparkle is a soft dependency. SparkleBridge.swift uses
// `#if canImport(Sparkle)` so the app still compiles and runs in
// offline / dependency-resolution-failed environments. To explicitly skip
// the Sparkle dependency in such environments, set the env var
// `VOICEMODE_NO_SPARKLE=1` before `swift build`.
let useSparkle = ProcessInfo.processInfo.environment["VOICEMODE_NO_SPARKLE"] != "1"

let sparklePackages: [Package.Dependency] = useSparkle ? [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
] : []

let sparkleTargetDeps: [Target.Dependency] = useSparkle ? [
    .product(name: "Sparkle", package: "Sparkle"),
] : []

let package = Package(
    name: "VoiceModeMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VoiceModeMenuBar", targets: ["VoiceModeMenuBar"]),
    ],
    dependencies: sparklePackages,
    targets: [
        .executableTarget(
            name: "VoiceModeMenuBar",
            dependencies: sparkleTargetDeps,
            path: "Sources/VoiceModeMenuBar",
            exclude: ["Transcript/README.md"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
