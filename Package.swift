// swift-tools-version:5.9
import PackageDescription

// Builds DeskPad with just the Command Line Tools (no Xcode.app needed):
//   swift build -c release
// scripts/package-release.sh wraps this into a signed, zipped DeskPad.app.
let package = Package(
    name: "DeskPad",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/ReSwift/ReSwift.git", from: "6.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "DeskPad",
            dependencies: ["ReSwift"],
            path: "DeskPad",
            exclude: [
                "Assets.xcassets",
                "DeskPad.entitlements",
                "DeskPad-Bridging-Header.h",
                "CGVirtualDisplayPrivate.h",
            ],
            swiftSettings: [
                // The private CGVirtualDisplay API is declared in a header that Swift sees through
                // the same bridging header the Xcode project uses.
                .unsafeFlags(["-import-objc-header", "DeskPad/DeskPad-Bridging-Header.h"]),
            ]
        ),
    ]
)
