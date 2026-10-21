// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Trove",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Trove",
            path: "Sources/Trove",
            linkerSettings: [
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