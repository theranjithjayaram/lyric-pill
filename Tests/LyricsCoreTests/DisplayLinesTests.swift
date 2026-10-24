import LyricsCore

// All fixture text is invented plain language — no real song lyrics.
func displayLinesTests(_ t: TestReporter) {
    let hindi = DisplayLines.Config(sources: ["hi"], target: "en")
    let lines = [
        LrcLine(ms: 0, text: "आज आसमान बिल्कुल साफ है"),      // devanagari
        LrcLine(ms: 4000, text: "ਅੱਜ ਅਸਮਾਨ ਬਿਲਕੁਲ ਸਾਫ਼ ਹੈ"),    // gurmukhi — never translatable
        LrcLine(ms: 8000, text: "aaj aasmaan bilkul saaf hai"),  // romanized — latin
        LrcLine(ms: 12000, text: "मैं तुम्हारा दोस्त हूँ"),      // devanagari
    ]
    let miss: (String) -> String? = { _ in nil }
    let noRecognizer: (String, [String]) -> String? = { _, _ in nil }

    // MARK: plan — cache first

    let cachedText = LrcParser.serialize([
        LrcLine(ms: 0, text: "⇄ Today the sky is clear"),
        LrcLine(ms: 4000, text: "ਅੱਜ ਅਸਮਾਨ ਬਿਲਕੁਲ ਸਾਫ਼ ਹੈ"),
    ])
    var recognizerCalls = 0
    let replay = DisplayLines.plan(
        lines: lines, config: hindi, trackKey: "a|b|c|200",
        lookup: { _ in cachedText },
        recognizer: { _, _ in recognizerCalls += 1; return nil })
    t.expect(replay == .cached(LrcParser.parse(cachedText)),
             "plan: cached text replays as parsed display lines")
    t.expect(recognizerCalls == 0, "plan: a replay never consults the recognizer")

    t.expect(DisplayLines.plan(lines: lines, config: hindi, trackKey: "k",
                               lookup: { _ in "" }, recognizer: noRecognizer) != .nothing,
             "plan: an empty cache file is a miss")

    var seenKey = ""
    _ = DisplayLines.plan(lines: lines, config: hindi, trackKey: "a|b|c|200",
                          lookup: { seenKey = $0; return nil }, recognizer: noRecognizer)
    t.expect(seenKey == "a|b|c|200|" + LanguageGate.cacheKeySuffix(enabledSources: ["hi"], target: "en"),
             "plan: the cache key is the track key plus the gate's suffix")
    var otherKey = ""
    _ = DisplayLines.plan(lines: lines, config: DisplayLines.Config(sources: ["hi", "ru"], target: "en"),
                          trackKey: "a|b|c|200", lookup: { otherKey = $0; return nil },
                          recognizer: noRecognizer)
    t.expect(otherKey != seenKey, "plan: enabling another source changes the key")
    var sameKey = ""
    _ = DisplayLines.plan(lines: lines, config: DisplayLines.Config(sources: ["hi", "en"], target: "en"),
                          trackKey: "a|b|c|200", lookup: { sameKey = $0; return nil },
                          recognizer: noRecognizer)
    t.expect(sameKey == seenKey, "plan: a source that can't take part (the target) leaves the key alone")

    // MARK: plan — gate on a miss

    let planned = DisplayLines.plan(lines: lines, config: hindi, trackKey: "a|b|c|200",
                                    lookup: miss, recognizer: noRecognizer)
    t.expect(planned == .translate(batches: [TranslationBatch(source: "hi", indices: [0, 3])], cacheKey: seenKey),
             "plan: only the devanagari lines go to hi; gurmukhi and romanized never do (bug #5)")

    let english = [LrcLine(ms: 0, text: "The sky is clear today"), LrcLine(ms: 3000, text: "and the wind is calm")]
    t.expect(DisplayLines.plan(lines: english, config: hindi, trackKey: "k",
                               lookup: miss, recognizer: noRecognizer) == .nothing,
             "plan: nothing translatable is .nothing")

    var asked: [String] = []
    _ = DisplayLines.plan(lines: [LrcLine(ms: 0, text: "Сьогодні гарна погода")],
                          config: DisplayLines.Config(sources: ["ru", "uk"], target: "en"),
                          trackKey: "k", lookup: miss,
                          recognizer: { _, candidates in asked = candidates; return "uk" })
    t.expect(asked == ["ru", "uk"], "plan: a shared script consults the recognizer on a miss")

    // MARK: assemble

    let batch = TranslationBatch(source: "hi", indices: [0, 3])
    let good = DisplayLines.assemble(
        lines: lines, config: hindi,
        outcomes: [(batch, .translated(["Today the sky is clear", "I am your friend"]))])
    t.expect(good.display[0] == LrcLine(ms: 0, text: "⇄ Today the sky is clear")
             && good.display[3] == LrcLine(ms: 12000, text: "⇄ I am your friend"),
             "assemble: accepted texts are marked and keep their timestamps")
    t.expect(good.display[1] == lines[1] && good.display[2] == lines[2],
             "assemble: lines outside the batch are untouched")
    t.expect(good.display.filter { $0.text.hasPrefix(DisplayLines.marker) }.count == 2,
             "assemble: the marker is on exactly the accepted lines")
    t.expect(good.cacheText == LrcParser.serialize(good.display),
             "assemble: a fully translated result is cached")
    t.expect(good.cacheText.map(LrcParser.parse) == good.display,
             "assemble: the cached text replays to the same display lines")
    t.expect(good.skippedPacks.isEmpty, "assemble: nothing skipped")

    let echo = DisplayLines.assemble(
        lines: lines, config: hindi,
        outcomes: [(batch, .translated(["आज आसमान बिल्कुल साफ है", "मैं तुम्हारा दोस्त हूँ"]))])
    t.expect(echo.display == lines, "assemble: output in the wrong script keeps the originals, unmarked")
    t.expect(echo.cacheText == nil, "assemble: nothing accepted ⇒ nothing cached")

    let short = DisplayLines.assemble(
        lines: lines, config: hindi, outcomes: [(batch, .translated(["Today the sky is clear"]))])
    t.expect(short.display[0].text.hasPrefix("⇄ ") && short.display[3] == lines[3],
             "assemble: fewer texts than lines map to the first timestamps only")

    let missingPack = DisplayLines.assemble(
        lines: lines, config: hindi, outcomes: [(batch, .packNotDownloaded)])
    t.expect(missingPack.skippedPacks == ["hi"] && missingPack.display == lines && missingPack.cacheText == nil,
             "assemble: a missing pack is named for the status row and nothing is cached")

    let two = DisplayLines.Config(sources: ["hi", "es"], target: "en")
    let mixed = [LrcLine(ms: 0, text: "El cielo está claro"), LrcLine(ms: 3000, text: "आज आसमान साफ है")]
    let es = TranslationBatch(source: "es", indices: [0])
    let hi = TranslationBatch(source: "hi", indices: [1])
    let partial = DisplayLines.assemble(
        lines: mixed, config: two,
        outcomes: [(es, .packNotDownloaded), (hi, .translated(["The sky is clear today"]))])
    t.expect(partial.display[1].text == "⇄ The sky is clear today" && partial.display[0] == mixed[0],
             "assemble: the batches that answered are shown even when another pack is missing")
    t.expect(partial.cacheText == nil && partial.skippedPacks == ["es"],
             "assemble: a missing pack blocks caching so a later download takes effect")

    let failed = DisplayLines.assemble(
        lines: mixed, config: two,
        outcomes: [(es, .failed), (hi, .translated(["The sky is clear today"]))])
    t.expect(failed.display[1].text.hasPrefix("⇄ ") && failed.cacheText == nil,
             "assemble: a transient failure shows what it has but is not frozen")

    let skipped = DisplayLines.assemble(
        lines: mixed, config: two,
        outcomes: [(es, .skipped), (hi, .translated(["The sky is clear today"]))])
    t.expect(skipped.cacheText == nil, "assemble: a skipped batch is never cached")

    let unsupported = DisplayLines.assemble(
        lines: mixed, config: two,
        outcomes: [(es, .unsupported), (hi, .translated(["The sky is clear today"]))])
    t.expect(unsupported.cacheText != nil && unsupported.skippedPacks.isEmpty,
             "assemble: an unsupported pair is deterministic and does not block caching")

    let none = DisplayLines.assemble(lines: lines, config: hindi, outcomes: [])
    t.expect(none.display == lines && none.cacheText == nil && none.skippedPacks.isEmpty,
             "assemble: no outcomes ⇒ originals, nothing cached")

    let outOfRange = DisplayLines.assemble(
        lines: lines, config: hindi,
        outcomes: [(TranslationBatch(source: "hi", indices: [9]), .translated(["Out of range"]))])
    t.expect(outOfRange.display == lines, "assemble: an index past the lines is ignored")
}
