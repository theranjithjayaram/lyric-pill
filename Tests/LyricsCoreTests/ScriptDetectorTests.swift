import LyricsCore

func scriptDetectorTests(_ t: TestReporter) {
    t.expect(ScriptDetector.isMostlyDevanagari("तू जो रूठा तो कौन हँसेगा"),
             "script: devanagari detected")
    t.expect(!ScriptDetector.isMostlyDevanagari("Tu jo rootha toh kaun hasega"),
             "script: romanized hindi is not devanagari")
    t.expect(!ScriptDetector.isMostlyDevanagari("If you are silent, who will laugh?"),
             "script: english is not devanagari")
    t.expect(ScriptDetector.isMostlyDevanagari("तेरा yaar हूँ main"),
             "script: mixed line above threshold detected")
    t.expect(!ScriptDetector.isMostlyDevanagari(""),
             "script: empty text is not devanagari")
    t.expect(!ScriptDetector.isMostlyDevanagari("... 123 !!!"),
             "script: no letters is not devanagari")

    t.expect(!ScriptDetector.isMostlyDevanagari("ਮੈਨੂੰ ਚੜ੍ਹਿਆ ਇਸ਼ਕ ਮੇਂ ਰੰਗ ਤੇਰਾ"),
             "script: gurmukhi line is not devanagari")

    t.expect(ScriptDetector.isMostlyLatin("Even if you are not close, you were always near"),
             "script: english output is latin")
    t.expect(!ScriptDetector.isMostlyLatin("ਇੱਕ ਹੋਿਗਾ ਅੰਗ ਮੇਰਾ, ਅੰਗ"),
             "script: mangled gurmukhi output is not latin")
    t.expect(!ScriptDetector.isMostlyLatin("तेरा यार हूँ मैं"),
             "script: devanagari passthrough is not latin")
    t.expect(!ScriptDetector.isMostlyLatin("…"), "script: no letters is not latin")

    // serialize/parse round-trip (used by the translation cache)
    let lines = [LrcLine(ms: 0, text: "a"), LrcLine(ms: 62345, text: "line two")]
    t.expect(LrcParser.parse(LrcParser.serialize(lines)) == lines,
             "serialize: round-trips through the parser")
}
