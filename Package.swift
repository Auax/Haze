// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Haze",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Haze", targets: ["Haze"])
    ],
    targets: [
        .executableTarget(
            name: "Haze",
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
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
