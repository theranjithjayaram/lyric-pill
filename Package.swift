// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LyricPill",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic (LRC parsing, timing, lrclib fetch) — unit-tested, no AppKit.
        .target(
            name: "LyricsCore",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // The menu-bar app: Spotify watcher, overlay panel, status item.
        .executableTarget(
            name: "LyricPill",
            dependencies: ["LyricsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // Plain executable test runner (`swift run lyrics-tests`): Command Line
        // Tools ship neither XCTest nor Swift Testing, both need full Xcode.
        .executableTarget(
            name: "lyrics-tests",
            dependencies: ["LyricsCore"],
            path: "Tests/LyricsCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
