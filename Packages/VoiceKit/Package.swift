// swift-tools-version: 6.2
//
// Screendrop Voice's audio engine: the voice chain, loudness and spectrum
// measurement, voice profiles, the per-track processing taps, voice
// isolation, and the microphone check's analysis. No UI and no dependency
// on the app, so it builds and tests on its own:
//
//   swift build --package-path Packages/VoiceKit

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
        .library(name: "VoiceKit", targets: ["VoiceKit"])
    ],
    targets: [
        .target(name: "VoiceKit", swiftSettings: swiftSettings)
    ],
    swiftLanguageModes: [.v5]
)
