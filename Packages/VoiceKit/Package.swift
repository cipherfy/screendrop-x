// swift-tools-version: 6.2
//
// Screendrop X's audio engine: the voice chain, loudness and spectrum
// measurement, voice profiles, the per-track processing taps, voice
// isolation, and the microphone check's analysis. No UI and no dependency
// on the app, so it builds and tests on its own:
//
//   swift test -c release --package-path Packages/VoiceKit
//
// The app links only the VoiceKit library. The voice-bank and
// render-voice-ab tools and the tests share VoiceKitTestSupport.

import PackageDescription

// The app's concurrency settings (Swift 5 mode, approachable concurrency),
// so the engine behaves the same here as it did compiled into the app.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "VoiceKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VoiceKit", targets: ["VoiceKit"]),
        .executable(name: "voice-bank", targets: ["VoiceBankTool"]),
        .executable(name: "render-voice-ab", targets: ["RenderVoiceAB"])
    ],
    targets: [
        .target(name: "VoiceKit", swiftSettings: swiftSettings),
        .target(name: "VoiceKitTestSupport", dependencies: ["VoiceKit"], swiftSettings: swiftSettings),
        .executableTarget(name: "VoiceBankTool", dependencies: ["VoiceKit", "VoiceKitTestSupport"], swiftSettings: swiftSettings),
        .executableTarget(name: "RenderVoiceAB", dependencies: ["VoiceKit", "VoiceKitTestSupport"], swiftSettings: swiftSettings),
        .testTarget(name: "VoiceKitTests", dependencies: ["VoiceKit", "VoiceKitTestSupport"], swiftSettings: swiftSettings)
    ],
    swiftLanguageModes: [.v5]
)
