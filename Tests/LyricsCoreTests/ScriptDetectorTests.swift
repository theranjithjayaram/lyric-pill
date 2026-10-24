import LyricsCore

// All fixture text is invented plain language — no real song lyrics.
func scriptDetectorTests(_ t: TestReporter) {
    // dominantScript: one script per line, kana rule for Japanese
    let dominant: [(String, Script?, String)] = [
        ("今日は天気がいい", .kana, "kanji mixed with kana is kana"),
        ("今天天气很好", .han, "pure han is han"),
        ("오늘 날씨가 좋다", .hangul, "hangul"),
        ("วันนี้อากาศดี", .thai, "thai"),
        ("الطقس جميل اليوم", .arabic, "arabic"),
        ("Hôm nay trời rất đẹp", .latin, "vietnamese with diacritics is latin"),
        ("The sky is perfectly clear today", .latin, "english is latin"),
        ("aaj aasmaan bilkul saaf hai", .latin, "romanized hindi is latin, not devanagari"),
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
}
