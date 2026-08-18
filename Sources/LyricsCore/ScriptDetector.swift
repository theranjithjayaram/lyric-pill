import Foundation

public enum ScriptDetector {
    /// True when a meaningful share (≥30%) of the text's letters are
    /// Devanagari — i.e. the lyrics are written in Hindi script, as opposed to
    /// romanized Hindi or a community-uploaded English translation. The
    /// threshold tolerates mixed lines (English loan words inside Hindi text).
    public static func isMostlyDevanagari(_ text: String) -> Bool {
        var devanagari = 0
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if (0x0900...0x097F).contains(scalar.value) {
                devanagari += 1
            }
        }
        return letters > 0 && devanagari * 10 >= letters * 3
    }
}
