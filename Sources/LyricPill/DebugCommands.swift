import AppKit
import LyricsCore

/// The debug flags' bodies — `main.swift` only dispatches. Each prints its
/// check to stdout and exits; none returns to the normal launch.
enum DebugCommands {
    /// `--engine-check f.lrc`: parse, then the engine's pick at fixed positions.
    static func engineCheck(lrcPath: String) -> Never {
        let text = (try? String(contentsOfFile: lrcPath, encoding: .utf8)) ?? ""
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

    // Keeps the translator (and its host window) alive until the process exits.
    private static var retainedTranslator: AnyObject?

    /// `--translate-check f.lrc`: the display-lines pipeline with every catalog
    /// language enabled (target English) — what each line would become, with
    /// the raw model answers and the cache decision alongside.
    @available(macOS 15.0, *)
    static func translateCheck(lrcPath: String) -> Never {
        guard let text = try? String(contentsOfFile: lrcPath, encoding: .utf8) else {
            warn("cannot read \(lrcPath)")
            exit(1)
        }
        let lines = LrcParser.parse(text)
        let config = DisplayLines.Config(
            sources: Set(TranslationCatalog.languages.map(\.id)), target: "en")
        let plan = DisplayLines.plan(
            lines: lines, config: config, trackKey: "translate-check",
            lookup: { _ in nil }, recognizer: AppleLanguageRecognizer.recognize)
        guard case .translate(let batches, _) = plan else {
            print("nothing to translate — would be shown as-is")
            exit(0)
        }
        warn("lines: \(lines.count), batches: \(batches.count)")
        let planned = Set(batches.flatMap(\.indices))
        for (index, line) in lines.enumerated() where !planned.contains(index) {
            print("[\(line.ms)ms] left alone: \(line.text)")
        }

        let translator = LyricsTranslator()
        retainedTranslator = translator
        var outcomes: [(batch: TranslationBatch, outcome: TranslateOutcome)] = []
        DispatchQueue.main.async {
            for batch in batches {
                print("batch \(batch.source) → \(config.target): lines \(batch.indices)")
                translator.translate(lines: batch.indices.map { lines[$0].text },
                                     from: batch.source, to: config.target) { outcome in
                    report(batch, outcome, lines: lines, target: config.target)
                    outcomes.append((batch, outcome))
                    guard outcomes.count == batches.count else { return }
                    let result = DisplayLines.assemble(lines: lines, config: config, outcomes: outcomes)
                    print("display:")
                    for line in result.display {
                        print("[\(line.ms)ms] \(line.text)")
                    }
                    if !result.skippedPacks.isEmpty {
                        print("packs not downloaded: \(result.skippedPacks.joined(separator: ", "))")
                    }
                    print(result.cacheText == nil ? "would not cache" : "would cache")
                    exit(0)
                }
            }
        }
        NSApplication.shared.run()
        fatalError("unreachable")
    }

    /// One batch's raw answer, marking texts the pipeline would reject.
    private static func report(_ batch: TranslationBatch, _ outcome: TranslateOutcome,
                               lines: [LrcLine], target: String) {
        let pair = "batch \(batch.source) → \(target)"
        switch outcome {
        case .translated(let texts):
            for (j, index) in batch.indices.enumerated() where j < texts.count {
                let accepted = LanguageGate.isPlausibleOutput(texts[j], target: target)
                print("[\(lines[index].ms)ms] \(batch.source): \(lines[index].text) → "
                      + texts[j] + (accepted ? "" : "  (rejected: not \(target))"))
            }
        case .packNotDownloaded: print("\(pair): pack not downloaded")
        case .unsupported: print("\(pair): pair unsupported")
        case .failed: print("\(pair): translation failed")
        case .skipped: print("\(pair): skipped")
        }
    }

    /// `--snapshot-pill out.png`: render the pill with a line to a PNG and exit.
    static func snapshotPill(to output: String) -> Never {
        let overlay = OverlayWindow(savedCenter: nil)
        overlay.setText("one line at a time, until the end")
        overlay.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            overlay.snapshot(to: output)
            exit(0)
        }
        NSApplication.shared.run()
        fatalError("unreachable")
    }

    /// `--snapshot-settings out.png [general|translation|about]`: render the
    /// Settings window (fake pack statuses) to a PNG and exit — layout checks
    /// on a Mac without Screen Recording permission.
    static func snapshotSettings(to output: String, tab tabName: String?) -> Never {
        let tab: SettingsTab = switch tabName {
        case "general": .general
        case "about": .about
        default: .translation
        }
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
        settings.show(tab: tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {  // let .task load statuses
            settings.snapshot(to: output)
            exit(0)
        }
        NSApplication.shared.run()
        fatalError("unreachable")
    }
}
