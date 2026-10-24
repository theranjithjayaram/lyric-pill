import LyricsCore

func translationCatalogTests(_ t: TestReporter) {
    let languages = TranslationCatalog.languages
    t.expect(languages.count == 20, "catalog: 20 languages (Apple Translation, macOS 15)")
    t.expect(Set(languages.map(\.id)).count == languages.count, "catalog: ids unique")
    t.expect(languages.map(\.name) == languages.map(\.name).sorted(),
             "catalog: display order is alphabetical by name")
    t.expect(languages.allSatisfy { TranslationCatalog.normalize($0.id) == $0.id },
             "catalog: every id normalizes to itself")
    t.expect(TranslationCatalog.language(for: "hi")?.name == "Hindi", "catalog: language(for:) by id")
    t.expect(TranslationCatalog.language(for: "zh-Hans")?.script == .han,
             "catalog: Chinese ids carry the script tag")
    t.expect(TranslationCatalog.language(for: "xx") == nil, "catalog: unknown id is nil")

    // normalize: Apple-style identifiers → catalog ids
    let cases: [(String, String?)] = [
        ("en-US", "en"), ("pt-BR", "pt"), ("zh-Hans-CN", "zh-Hans"), ("zh", "zh-Hans"),
        ("zh-TW", "zh-Hant"), ("zh-HK", "zh-Hant"), ("zh-Hant", "zh-Hant"), ("zh-CN", "zh-Hans"),
        ("EN", "en"), ("en_US", "en"), ("hi-IN", "hi"), ("xx", nil), ("", nil), ("-", nil),
    ]
    for (input, expected) in cases {
        t.expect(TranslationCatalog.normalize(input) == expected,
                 "normalize: \(input.debugDescription) → \(expected.map { $0.debugDescription } ?? "nil")")
    }

    // candidates: who writes in which script
    t.expect(TranslationCatalog.candidates(for: .devanagari) == ["hi"], "candidates: devanagari → hi")
    t.expect(TranslationCatalog.candidates(for: .cyrillic) == ["ru", "uk"], "candidates: cyrillic → ru, uk")
    t.expect(TranslationCatalog.candidates(for: .han) == ["zh-Hans", "zh-Hant"],
             "candidates: han → both Chinese")
    t.expect(TranslationCatalog.candidates(for: .kana) == ["ja"], "candidates: kana → ja")
    t.expect(TranslationCatalog.candidates(for: .hangul) == ["ko"], "candidates: hangul → ko")
    t.expect(TranslationCatalog.candidates(for: .thai) == ["th"], "candidates: thai → th")
    t.expect(TranslationCatalog.candidates(for: .arabic) == ["ar"], "candidates: arabic → ar")
    t.expect(TranslationCatalog.candidates(for: .latin)
             == ["nl", "en", "fr", "de", "id", "it", "pl", "pt", "es", "tr", "vi"],
             "candidates: latin → all Latin-script languages in catalog order")
    t.expect(TranslationCatalog.candidates(for: .gurmukhi).isEmpty, "candidates: gurmukhi → none")
    t.expect(TranslationCatalog.candidates(for: .tamil).isEmpty, "candidates: tamil → none")
    t.expect(TranslationCatalog.candidates(for: .other).isEmpty, "candidates: other → none")
}
