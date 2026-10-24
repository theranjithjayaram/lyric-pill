import LyricsCore

// All fixture text is invented plain language — no real song lyrics.

/// Scripted recognizer: answers from a table keyed by line text (missing =
/// nil) and records every consultation, so tests can assert both *what* the
/// gate asked and *whether* it asked at all.
private final class FakeRecognizer {
    var answers: [String: String]
    private(set) var calls: [(text: String, constraints: [String])] = []

    init(_ answers: [String: String] = [:]) {
        self.answers = answers
    }

    func recognize(_ text: String, _ constraints: [String]) -> String? {
        calls.append((text, constraints))
        return answers[text]
    }
}

private let hindiLine = "आज आसमान बिल्कुल साफ है"
private let punjabiLine = "ਅੱਜ ਮੌਸਮ ਬਹੁਤ ਵਧੀਆ ਹੈ"
private let englishLine = "The sky is perfectly clear today"
private let spanishLine = "El cielo está totalmente despejado hoy"
private let ukrainianLine = "Сьогодні небо зовсім чисте"
private let thaiLine = "วันนี้ท้องฟ้าแจ่มใส"
private let japaneseLine = "今日は空がとても青い"   // kanji + kana
private let chineseLine = "今天天空非常蓝"         // Han only
private let vietnameseLine = "Hôm nay bầu trời rất trong"

func languageGateTests(_ t: TestReporter) {
    // Shorthand: the recognizer must never be consulted.
    func noRecognizer(_ text: String, _ constraints: [String]) -> String? {
        t.expect(false, "gate: recognizer consulted unexpectedly for \(text) among \(constraints)")
        return nil
    }

    t.expect(LanguageGate.plan(lines: [hindiLine], enabledSources: ["hi"], target: "en",
                               recognizer: noRecognizer)
             == [TranslationBatch(source: "hi", indices: [0])],
             "gate: devanagari line with hi enabled is translated from hi")

    let everything = Set(TranslationCatalog.languages.map(\.id))
    t.expect(LanguageGate.plan(lines: [punjabiLine], enabledSources: everything, target: "en",
                               recognizer: { _, _ in "hi" }).isEmpty,
             "gate: gurmukhi line is never translated, even with every language enabled")

    t.expect(LanguageGate.plan(lines: ["", "123", "… !!!", hindiLine], enabledSources: ["hi"],
                               target: "en", recognizer: noRecognizer)
             == [TranslationBatch(source: "hi", indices: [3])],
             "gate: empty, numeric and punctuation-only lines are skipped")

    t.expect(LanguageGate.plan(lines: [hindiLine], enabledSources: ["hi"], target: "hi",
                               recognizer: noRecognizer).isEmpty,
             "gate: target is removed from the sources")
    t.expect(LanguageGate.plan(lines: [englishLine], enabledSources: ["en", "hi"], target: "en",
                               recognizer: noRecognizer).isEmpty,
             "gate: latin line with only the target in latin is skipped without asking")
    t.expect(LanguageGate.plan(lines: [hindiLine], enabledSources: ["xx", "hi"], target: "en",
                               recognizer: noRecognizer)
             == [TranslationBatch(source: "hi", indices: [0])],
             "gate: unknown enabled ids are ignored")
    t.expect(LanguageGate.plan(lines: [hindiLine], enabledSources: ["hi"], target: "xx",
                               recognizer: noRecognizer).isEmpty,
             "gate: unknown target translates nothing")

    // Same script as the target: the line might already be English, so the
    // recognizer is asked with the target as a sink.
    do {
        let fake = FakeRecognizer([englishLine: "en"])
        t.expect(LanguageGate.plan(lines: [englishLine], enabledSources: ["es"], target: "en",
                                   recognizer: fake.recognize).isEmpty,
                 "gate: same-script line recognized as the target is skipped")
        t.expect(fake.calls.count == 1 && fake.calls[0].constraints == ["es", "en"],
                 "gate: same-script line asks among candidates plus target")
    }
    do {
        let fake = FakeRecognizer([spanishLine: "es"])
        t.expect(LanguageGate.plan(lines: [spanishLine], enabledSources: ["es"], target: "en",
                                   recognizer: fake.recognize)
                 == [TranslationBatch(source: "es", indices: [0])],
                 "gate: same-script line recognized as a candidate is translated")
    }
    do {
        let fake = FakeRecognizer()
        t.expect(LanguageGate.plan(lines: [spanishLine], enabledSources: ["es"], target: "en",
                                   recognizer: fake.recognize).isEmpty,
                 "gate: same-script line the recognizer can't place is skipped")
    }

    // Shared script, several candidates: the recognizer decides.
    do {
        let fake = FakeRecognizer([ukrainianLine: "uk"])
        t.expect(LanguageGate.plan(lines: [ukrainianLine], enabledSources: ["ru", "uk"], target: "en",
                                   recognizer: fake.recognize)
                 == [TranslationBatch(source: "uk", indices: [0])],
                 "gate: cyrillic with ru+uk enabled follows the recognizer")
        t.expect(fake.calls.count == 1 && fake.calls[0].constraints == ["ru", "uk"],
                 "gate: cyrillic with ru+uk asks among exactly those two")
    }
    do {
        let fake = FakeRecognizer([ukrainianLine: "en"])
        t.expect(LanguageGate.plan(lines: [ukrainianLine], enabledSources: ["ru", "uk"], target: "en",
                                   recognizer: fake.recognize).isEmpty,
                 "gate: a recognizer answer outside the candidates is ignored")
    }
    t.expect(LanguageGate.plan(lines: [ukrainianLine], enabledSources: ["ru"], target: "en",
                               recognizer: noRecognizer)
             == [TranslationBatch(source: "ru", indices: [0])],
             "gate: cyrillic with only ru enabled needs no recognizer")

    // Han vs Japanese is a rule: any kana → ja; pure Han → Chinese.
    t.expect(LanguageGate.plan(lines: [japaneseLine], enabledSources: ["ja", "zh-Hans"], target: "en",
                               recognizer: noRecognizer)
             == [TranslationBatch(source: "ja", indices: [0])],
             "gate: kanji+kana line goes to ja without a recognizer")
    t.expect(LanguageGate.plan(lines: [chineseLine], enabledSources: ["ja", "zh-Hans"], target: "en",
                               recognizer: noRecognizer)
             == [TranslationBatch(source: "zh-Hans", indices: [0])],
             "gate: han-only line goes to the single enabled Chinese")
    do {
        let fake = FakeRecognizer([chineseLine: "zh-Hant"])
        t.expect(LanguageGate.plan(lines: [chineseLine], enabledSources: ["zh-Hans", "zh-Hant"],
                                   target: "en", recognizer: fake.recognize)
                 == [TranslationBatch(source: "zh-Hant", indices: [0])],
                 "gate: han line with both Chinese variants enabled asks the recognizer")
        t.expect(fake.calls.count == 1 && fake.calls[0].constraints == ["zh-Hans", "zh-Hant"],
                 "gate: both Chinese variants offered in catalog order")
    }

    t.expect(LanguageGate.plan(lines: [ukrainianLine, hindiLine, ukrainianLine, thaiLine, ""],
                               enabledSources: ["th", "ru", "hi"], target: "en",
                               recognizer: noRecognizer)
             == [TranslationBatch(source: "hi", indices: [1]),
                 TranslationBatch(source: "ru", indices: [0, 2]),
                 TranslationBatch(source: "th", indices: [3])],
             "gate: batches sorted by source id with ascending indices")

    // Output validation: the target's script, nothing else.
    t.expect(LanguageGate.isPlausibleOutput(englishLine, target: "en"),
             "plausible: english output for en")
    t.expect(LanguageGate.isPlausibleOutput(vietnameseLine, target: "vi"),
             "plausible: vietnamese diacritics count as latin for vi")
    t.expect(!LanguageGate.isPlausibleOutput(hindiLine, target: "en"),
             "plausible: devanagari passthrough rejected for en")
    t.expect(!LanguageGate.isPlausibleOutput("", target: "en"), "plausible: empty rejected")
    t.expect(!LanguageGate.isPlausibleOutput("… 42", target: "en"),
             "plausible: letterless rejected")
    t.expect(LanguageGate.isPlausibleOutput(hindiLine, target: "hi"),
             "plausible: devanagari output for hi")
    t.expect(LanguageGate.isPlausibleOutput(chineseLine, target: "zh-Hans"),
             "plausible: han output for zh-Hans")
    t.expect(LanguageGate.isPlausibleOutput(japaneseLine, target: "ja"),
             "plausible: kana-bearing output for ja")
    t.expect(!LanguageGate.isPlausibleOutput(chineseLine, target: "ja"),
             "plausible: kana-free output rejected for ja")
    t.expect(!LanguageGate.isPlausibleOutput(englishLine, target: "xx"),
             "plausible: unknown target rejects everything")

    // Cache key: sorted, stable, built from the effective sources.
    t.expect(LanguageGate.cacheKeySuffix(enabledSources: ["ru", "hi"], target: "en") == "tr-en-hi,ru-v3",
             "cache key: sources sorted")
    t.expect(LanguageGate.cacheKeySuffix(enabledSources: ["ru", "hi"], target: "en")
             == LanguageGate.cacheKeySuffix(enabledSources: ["hi", "ru"], target: "en"),
             "cache key: stable across set order")
    t.expect(LanguageGate.cacheKeySuffix(enabledSources: ["en", "hi", "xx"], target: "en") == "tr-en-hi-v3",
             "cache key: target and unknown ids don't take part")
    t.expect(LanguageGate.cacheKeySuffix(enabledSources: ["hi"], target: "en")
             != LanguageGate.cacheKeySuffix(enabledSources: ["hi"], target: "fr"),
             "cache key: target changes the key")
}
