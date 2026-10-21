// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Trove",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Trove",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Trove",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("LinkPresentation"),
            ]
        )
    ]
)
