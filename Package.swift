// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalTranslate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LocalTranslate",
            path: "Sources/LocalTranslate",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
