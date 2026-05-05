// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FocusRecorder",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "FocusRecorder", targets: ["FocusRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "FocusRecorder",
            resources: [
                .copy("Resources/Cursors")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
