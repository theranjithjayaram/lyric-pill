import Foundation

/// One language Apple's on-device Translation framework can translate to or
/// from. `id` is what the app persists and the gate reasons about; it is also
/// a valid `Locale.Language` / `NLLanguage` identifier.
public struct TranslationLanguage: Equatable {
    public let id: String      // "en", "hi", "zh-Hans", … (language code, plus "-Hans"/"-Hant" script for Chinese)
    public let name: String    // English display name, e.g. "Hindi", "Chinese (Simplified)"
    public let script: Script  // the writing system its lyrics are detected by
}

/// The fixed table of (language, script) pairs the translation gate works
/// from — the generalisation of the old hi/Devanagari constants.
public enum TranslationCatalog {
    /// Every language Apple's on-device Translation framework offers (macOS 15), in display order.
    public static let languages: [TranslationLanguage] = [
        TranslationLanguage(id: "ar", name: "Arabic", script: .arabic),
        TranslationLanguage(id: "zh-Hans", name: "Chinese (Simplified)", script: .han),
        TranslationLanguage(id: "zh-Hant", name: "Chinese (Traditional)", script: .han),
        TranslationLanguage(id: "nl", name: "Dutch", script: .latin),
        TranslationLanguage(id: "en", name: "English", script: .latin),
        TranslationLanguage(id: "fr", name: "French", script: .latin),
        TranslationLanguage(id: "de", name: "German", script: .latin),
        TranslationLanguage(id: "hi", name: "Hindi", script: .devanagari),
        TranslationLanguage(id: "id", name: "Indonesian", script: .latin),
        TranslationLanguage(id: "it", name: "Italian", script: .latin),
        TranslationLanguage(id: "ja", name: "Japanese", script: .kana),
        TranslationLanguage(id: "ko", name: "Korean", script: .hangul),
        TranslationLanguage(id: "pl", name: "Polish", script: .latin),
        TranslationLanguage(id: "pt", name: "Portuguese", script: .latin),
        TranslationLanguage(id: "ru", name: "Russian", script: .cyrillic),
        TranslationLanguage(id: "es", name: "Spanish", script: .latin),
        TranslationLanguage(id: "th", name: "Thai", script: .thai),
        TranslationLanguage(id: "tr", name: "Turkish", script: .latin),
        TranslationLanguage(id: "uk", name: "Ukrainian", script: .cyrillic),
        TranslationLanguage(id: "vi", name: "Vietnamese", script: .latin),
    ]

    public static func language(for id: String) -> TranslationLanguage? {
        languages.first { $0.id == id }
    }

    /// Display name, falling back to the id for anything outside the catalog.
    public static func name(for id: String) -> String {
        language(for: id)?.name ?? id
    }

    /// Catalog languages written in `script`, in catalog order.
    public static func candidates(for script: Script) -> [String] {
        languages.filter { $0.script == script }.map(\.id)
    }

    /// Normalises Apple-style identifiers to catalog ids: "en-US" → "en",
    /// "pt-BR" → "pt", "zh-Hans-CN" → "zh-Hans"; bare "zh" defaults to
    /// Simplified, "zh-TW"/"zh-HK" (and "zh-MO") mean Traditional. Also accepts
    /// the "_" form `Locale.identifier` produces. nil if not in the catalog.
    public static func normalize(_ identifier: String) -> String? {
        let parts = identifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.lowercased() }
        guard let code = parts.first else { return nil }
        if code == "zh" {
            // Chinese is the one language the catalog splits by script, and
            // Apple spells it either by script or by region.
            let traditional = ["hant", "tw", "hk", "mo"]
            return parts.dropFirst().contains(where: traditional.contains) ? "zh-Hant" : "zh-Hans"
        }
        return language(for: code)?.id
    }
}
