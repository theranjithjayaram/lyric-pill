import AppKit
import LyricsCore

/// Diagnostics go to stderr so stdout stays clean for the debug flags' output.
func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// The argument after `flag`; nil when the flag is absent. A bare flag is a
/// usage error, not a silent fall-through into a normal launch.
func value(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag) else { return nil }
    guard index + 1 < CommandLine.arguments.count else {
        warn("\(flag) needs a value")
        exit(2)
    }
    return CommandLine.arguments[index + 1]
}

// Single-instance guard: the login item and a manual `open` must not stack.
if let bundleId = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty {
        exit(0)
    }
}

if let path = value(after: "--engine-check") {
    DebugCommands.engineCheck(lrcPath: path)
}

let app = NSApplication.shared
// .accessory keeps us out of the Dock even when run unbundled (`swift run`);
// the bundled app also sets LSUIElement.
app.setActivationPolicy(.accessory)

if let path = value(after: "--translate-check") {
    if #available(macOS 15.0, *) {
        DebugCommands.translateCheck(lrcPath: path)
    }
    warn("--translate-check requires macOS 15+")
    exit(1)
}
if let output = value(after: "--snapshot-settings") {
    // An optional tab name may follow the path.
    let index = CommandLine.arguments.firstIndex(of: output)! + 1
    let tab = index < CommandLine.arguments.count ? CommandLine.arguments[index] : nil
    DebugCommands.snapshotSettings(to: output, tab: tab)
}
if let output = value(after: "--snapshot-pill") {
    DebugCommands.snapshotPill(to: output)
}

// `--simulate f.lrc` drives the overlay with no Spotify; `--settings [tab]`
// opens the Settings window at start (verification without clicking).
var settingsAtStart: SettingsTab?
if let index = CommandLine.arguments.firstIndex(of: "--settings") {
    let next = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : ""
    settingsAtStart = switch next {
    case "translation": .translation
    case "about": .about
    default: .general
    }
}
let controller = AppController(simulateLrcPath: value(after: "--simulate"),
                               showSettingsAtStart: settingsAtStart)
controller.start()
app.run()
