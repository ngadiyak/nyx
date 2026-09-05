// swift-tools-version:5.10
import PackageDescription

/// Release-only settings for this root package's own Swift targets.
///
/// `-enforce-exclusivity=unchecked` drops the *dynamic* exclusivity checks (`swift_beginAccess`
/// and its thread-local access set), which the profiler showed to be a third of the parse+model
/// path: every `screen.rows[y]...` mutation on a class stored property paid one. Debug builds --
/// including everything `swift test` runs -- keep the checks, so a real overlapping access still
/// gets caught. `-cross-module-optimization` lets `NyxRender`, `Nyx` and `nyx-bench` specialise
/// and inline across the `NyxCore` boundary.
///
/// Note: `.unsafeFlags` makes this package unusable as a SwiftPM *dependency* -- SwiftPM refuses to
/// resolve a package that declares them. That is fine for a leaf application, but if `NyxCore` is
/// ever split out into its own reusable package, these flags have to move to a build-time setting
/// or be dropped.
let releaseSettings: [SwiftSetting] = [
    .unsafeFlags(["-enforce-exclusivity=unchecked", "-cross-module-optimization"], .when(configuration: .release))
]

let package = Package(
    name: "Nyx",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CNyxPTY", path: "Sources/CNyxPTY"),
        .target(name: "NyxCore", dependencies: ["CNyxPTY"], path: "Sources/NyxCore", swiftSettings: releaseSettings),
        .target(
            name: "NyxRender",
            dependencies: ["NyxCore"],
            path: "Sources/NyxRender",
            swiftSettings: releaseSettings,
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("CoreText"), .linkedFramework("QuartzCore")]
        ),
        .target(name: "NyxRemote", dependencies: ["NyxCore"], path: "Sources/NyxRemote", swiftSettings: releaseSettings),
        .executableTarget(
            name: "Nyx",
            dependencies: ["NyxCore", "NyxRender", "NyxRemote"],
            path: "Sources/NyxApp",
            swiftSettings: releaseSettings,
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "nyx-bench", dependencies: ["NyxCore"], path: "Sources/NyxBench", swiftSettings: releaseSettings),
        .testTarget(name: "NyxCoreTests", dependencies: ["NyxCore"], path: "Tests/NyxCoreTests"),
        .testTarget(name: "NyxRenderTests", dependencies: ["NyxRender"], path: "Tests/NyxRenderTests"),
        .testTarget(name: "NyxRemoteTests", dependencies: ["NyxRemote"], path: "Tests/NyxRemoteTests"),
    ]
)
