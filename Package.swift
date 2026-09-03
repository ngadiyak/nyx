// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nyx",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CNyxPTY", path: "Sources/CNyxPTY"),
        .target(name: "NyxCore", dependencies: ["CNyxPTY"], path: "Sources/NyxCore"),
        .target(
            name: "NyxRender",
            dependencies: ["NyxCore"],
            path: "Sources/NyxRender",
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("CoreText"), .linkedFramework("QuartzCore")]
        ),
        .executableTarget(
            name: "Nyx",
            dependencies: ["NyxCore", "NyxRender"],
            path: "Sources/NyxApp",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "nyx-bench", dependencies: ["NyxCore"], path: "Sources/NyxBench"),
        .testTarget(name: "NyxCoreTests", dependencies: ["NyxCore"], path: "Tests/NyxCoreTests"),
        .testTarget(name: "NyxRenderTests", dependencies: ["NyxRender"], path: "Tests/NyxRenderTests"),
    ]
)
