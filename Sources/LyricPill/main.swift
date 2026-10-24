import AppKit
import LyricsCore

// Single-instance guard: the LaunchAgent and a manual `open` must not stack.
if let bundleId = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty {
        exit(0)
    }
}

// Debug: print the engine's selected line at fixed positions for an LRC file.
if let flag = CommandLine.arguments.firstIndex(of: "--engine-check"),
   flag + 1 < CommandLine.arguments.count {
    let text = (try? String(contentsOfFile: CommandLine.arguments[flag + 1], encoding: .utf8)) ?? ""
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

if let flag = CommandLine.arguments.firstIndex(of: "--translate-check"),
   flag + 1 < CommandLine.arguments.count {
    if #available(macOS 15.0, *) {
        TranslateCheck.run(lrcPath: CommandLine.arguments[flag + 1])
    }
    FileHandle.standardError.write(Data("--translate-check requires macOS 15+\n".utf8))
    exit(1)
}

var simulatePath: String?
if let flag = CommandLine.arguments.firstIndex(of: "--simulate"),
   flag + 1 < CommandLine.arguments.count {
    simulatePath = CommandLine.arguments[flag + 1]
}
// Debug: open the Settings window right at start (verification without clicking).
let showSettings = CommandLine.arguments.contains("--settings")

// Debug: render the Settings window (Translation tab, fake pack statuses) to a
// PNG and exit — layout checks on a Mac without Screen Recording permission.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-settings"),
   flag + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let output = CommandLine.arguments[flag + 1]
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

let app = NSApplication.shared
// .accessory keeps us out of the Dock even when run unbundled (`swift run`);
// the bundled app also sets LSUIElement.
app.setActivationPolicy(.accessory)

let controller = AppController(simulateLrcPath: simulatePath, showSettingsAtStart: showSettings)
controller.start()
app.run()
