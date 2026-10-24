import LyricsCore

// All fixture text is invented plain language — no real song lyrics.
func scriptDetectorTests(_ t: TestReporter) {
    t.expect(ScriptDetector.isMostlyDevanagari("आज आसमान बिल्कुल साफ है"),
             "script: devanagari detected")
    t.expect(!ScriptDetector.isMostlyDevanagari("aaj aasmaan bilkul saaf hai"),
             "script: romanized hindi is not devanagari")
    t.expect(!ScriptDetector.isMostlyDevanagari("The sky is perfectly clear today"),
             "script: english is not devanagari")
    t.expect(ScriptDetector.isMostlyDevanagari("मेरा best दोस्त है"),
             "script: mixed line above threshold detected")
    t.expect(!ScriptDetector.isMostlyDevanagari(""),
             "script: empty text is not devanagari")
    t.expect(!ScriptDetector.isMostlyDevanagari("... 123 !!!"),
             "script: no letters is not devanagari")

    t.expect(!ScriptDetector.isMostlyDevanagari("ਅੱਜ ਮੌਸਮ ਬਹੁਤ ਵਧੀਆ ਹੈ"),
             "script: gurmukhi line is not devanagari")

    t.expect(ScriptDetector.isMostlyLatin("The day is bright and the night is calm"),
             "script: english output is latin")
    t.expect(!ScriptDetector.isMostlyLatin("ਅੱਜ ਮੌਸਮ ਵਧੀਆ ਹੈ"),
             "script: gurmukhi output is not latin")
    t.expect(!ScriptDetector.isMostlyLatin("मैं तुम्हारा दोस्त हूँ"),
             "script: devanagari passthrough is not latin")
    t.expect(!ScriptDetector.isMostlyLatin("…"), "script: no letters is not latin")
    t.expect(ScriptDetector.isMostlyLatin("Hôm nay trời rất đẹp"),
             "script: vietnamese diacritics (Latin Extended Additional) are latin")

    // dominantScript: one script per line, kana rule for Japanese
    let dominant: [(String, Script?, String)] = [
        ("今日は天気がいい", .kana, "kanji mixed with kana is kana"),
        ("今天天气很好", .han, "pure han is han"),
        ("오늘 날씨가 좋다", .hangul, "hangul"),
        ("วันนี้อากาศดี", .thai, "thai"),
        ("الطقس جميل اليوم", .arabic, "arabic"),
        ("Hôm nay trời rất đẹp", .latin, "vietnamese with diacritics is latin"),
        ("Сьогодні гарна погода", .cyrillic, "cyrillic"),
        ("Ο καιρός είναι καλός", .greek, "greek"),
        ("מזג האוויר יפה היום", .hebrew, "hebrew"),
        ("आज मौसम अच्छा है", .devanagari, "devanagari"),
        ("আজ আবহাওয়া ভালো", .bengali, "bengali"),
        ("ਅੱਜ ਮੌਸਮ ਵਧੀਆ ਹੈ", .gurmukhi, "gurmukhi"),
        ("இன்று வானிலை நன்றாக உள்ளது", .tamil, "tamil"),
        ("მზიანი დღეა", .other, "georgian is other"),
        ("मेरा best दोस्त है", .devanagari, "majority wins in a mixed line"),
        ("ab कख", .latin, "a tie goes to the earlier case"),
        ("", nil, "empty is nil"),
        ("123 … !!!", nil, "no letters is nil"),
    ]
    for (text, expected, name) in dominant {
        t.expect(ScriptDetector.dominantScript(text) == expected, "dominant: \(name)")
    }

    // serialize/parse round-trip (used by the translation cache)
    let lines = [LrcLine(ms: 0, text: "a"), LrcLine(ms: 62345, text: "line two")]
    t.expect(LrcParser.parse(LrcParser.serialize(lines)) == lines,
             "serialize: round-trips through the parser")
}
