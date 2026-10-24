import LyricsCore

// All fixture text is invented plain language — no real song lyrics.
// These exercise the real NLLanguageRecognizer, so only clear-cut sentences:
// the gate's threshold is fixed at 0.5 and must not be loosened for a test.
func appleLanguageRecognizerTests(_ t: TestReporter) {
    t.expect(AppleLanguageRecognizer.recognize(
                "The weather is pleasant and the garden is quiet this morning",
                among: ["en", "es"]) == "en",
             "recognizer: clearly English among en/es")
    t.expect(AppleLanguageRecognizer.recognize(
                "El tiempo es agradable y el jardín está tranquilo esta mañana",
                among: ["en", "es"]) == "es",
             "recognizer: clearly Spanish among en/es")
    // ї, є and ґ exist only in Ukrainian.
    t.expect(AppleLanguageRecognizer.recognize(
                "Її дім є біля ґанку, а погода сьогодні приємна",
                among: ["ru", "uk"]) == "uk",
             "recognizer: Ukrainian letters among ru/uk")
    t.expect(AppleLanguageRecognizer.recognize(
                "Сегодня хорошая погода и мы идём гулять в парк",
                among: ["ru", "uk"]) == "ru",
             "recognizer: Russian among ru/uk")
    t.expect(AppleLanguageRecognizer.recognize("anything", among: []) == nil,
             "recognizer: no constraints → nil")
}
