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

// Debug: print the engine's selected line at fixed positions for an LRC file.
if let path = value(after: "--engine-check") {
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let lines = LrcParser.parse(text)
    print("parsed \(lines.count) lines; first ms: \(lines.first?.ms ?? -1), last ms: \(lines.last?.ms ?? -1)")
    let engine = TimingEngine()
    engine.setLines(lines)
    for second in [1, 5, 10, 14, 18, 22, 61, 240] {
        engine.seek(toMs: second * 1000)
        print("t=\(second)s -> [\(engine.currentIndex())] \(engine.currentText())")
    }
    exit(0)
}

let app = NSApplication.shared
// .accessory keeps us out of the Dock even when run unbundled (`swift run`);
// the bundled app also sets LSUIElement.
app.setActivationPolicy(.accessory)

if let path = value(after: "--translate-check") {
    if #available(macOS 15.0, *) {
        TranslateCheck.run(lrcPath: path)
    }
    warn("--translate-check requires macOS 15+")
    exit(1)
}

let simulatePath = value(after: "--simulate")
// Debug: open the Settings window right at start (verification without clicking).
let showSettings = CommandLine.arguments.contains("--settings")

// Debug: render the Settings window (Translation tab, fake pack statuses) to a
// PNG and exit — layout checks on a Mac without Screen Recording permission.
if let output = value(after: "--snapshot-settings") {
    var services = SettingsServices(resetPillPosition: {}, translation: nil)
    services.translation = SettingsServices.Translation(
        supportedLanguageIDs: { Set(TranslationCatalog.languages.map(\.id)) },
        packStatus: { source, _ in
            switch source {
            case "hi": .installed
            case "ar": .unsupported
            default: .downloadable
            }
        },
        downloadPack: { _, _, completion in completion(false) })
    let settings = SettingsWindowController(services: services)
    settings.show(tab: .translation)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {  // let .task load statuses
        settings.snapshot(to: output)
        exit(0)
    }
    app.run()
}

let controller = AppController(simulateLrcPath: simulatePath, showSettingsAtStart: showSettings)
controller.start()
app.run()
