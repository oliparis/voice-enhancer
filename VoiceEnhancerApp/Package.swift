// swift-tools-version:5.9
//
// Swift Package Manager manifest.
//
// This package exists primarily for quick compile checks during development
// (`swift build`). The final shipping artifact is a full .app bundle produced
// by an Xcode project that links against AudioEngine's static library.
//
// Xcode project generation is deferred until the Swift code stabilizes —
// hand-written .xcodeproj churn is noisy and a waste of diff review.

import PackageDescription

let package = Package(
    name: "VoiceEnhancer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VoiceEnhancer", targets: ["VoiceEnhancer"])
    ],
    targets: [
        .target(name: "CaptureLifecycle", path: "Sources/Audio/Lifecycle"),
        .executableTarget(name: "CaptureRecoveryTests", dependencies: ["CaptureLifecycle"],
                          path: "Tests/CaptureRecoveryTests"),
        .executableTarget(name: "CaptureLifecycleTests", dependencies: ["CaptureLifecycle"],
                          path: "Tests/CaptureLifecycleTests"),
        .target(
            name: "VoiceEnhancerTapSupport",
            path: "Sources/Audio/TapSupport",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", "-fobjc-arc-exceptions"])],
            linkerSettings: [.linkedFramework("AVFoundation")]
        ),
        .executableTarget(
            name: "VoiceEnhancer",
            dependencies: ["VoiceEnhancerTapSupport", "CaptureLifecycle"],
            path: "Sources",
            exclude: ["Resources/Info.plist", "Audio/TapSupport", "Audio/Lifecycle"],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
            // NOTE: When building inside Xcode, the AudioEngine static library
            // is linked via an Xcode build setting. For swift build we stub
            // the engine — see Audio/AudioEngineBridge.swift.
        ),
        // A microphone-free native regression runner. It exercises the
        // exact Objective-C helper linked into both app build paths.
        .executableTarget(
            name: "TapSupportTests",
            dependencies: ["VoiceEnhancerTapSupport"],
            path: "Tests/TapSupportTests",
            cSettings: [.unsafeFlags(["-fobjc-arc", "-fobjc-arc-exceptions"])],
            linkerSettings: [.linkedFramework("AVFoundation")]
        )
    ]
)
