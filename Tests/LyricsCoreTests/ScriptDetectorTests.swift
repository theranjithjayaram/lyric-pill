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

    // serialize/parse round-trip (used by the translation cache)
    let lines = [LrcLine(ms: 0, text: "a"), LrcLine(ms: 62345, text: "line two")]
    t.expect(LrcParser.parse(LrcParser.serialize(lines)) == lines,
             "serialize: round-trips through the parser")
}
