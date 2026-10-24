import NaturalLanguage

/// NLLanguageRecognizer shaped to be the `recognizer` argument of
/// `LanguageGate.plan` — the only place a model, rather than a rule, gets a
/// say, and only between languages that share a script.
public enum AppleLanguageRecognizer {
    /// Below this the gate leaves the line alone: a wrong source model yields
    /// garbage, no translation is the safer failure.
    private static let minimumProbability = 0.5

    /// Returns the language NLLanguageRecognizer finds dominant in `text` if
    /// it is one of `constraints` and its probability is ≥ 0.5, else nil.
    ///
    /// Deliberately NOT `languageConstraints`: that renormalises over the
    /// candidates and forces a pick, so romanised Hindi (no candidate is
    /// right) came back as "Indonesian" at high confidence. Unconstrained,
    /// such text lands on some language outside the candidates and is
    /// skipped. A fresh recognizer per call — cheap, no state between lines.
    public static func recognize(_ text: String, among constraints: [String]) -> String? {
        guard !constraints.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        // "zh-Hans"/"zh-Hant" are NLLanguage's own raw values, as are the plain codes.
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.value >= minimumProbability,
              constraints.contains(best.key.rawValue)
        else { return nil }
        return best.key.rawValue
    }
}
