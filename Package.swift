// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "SoftEtherVPN",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "SoftEtherVPN",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
            ]
        ),
    ]
)
