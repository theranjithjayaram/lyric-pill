import Foundation

/// Writing systems the translation gate tells apart — one per script Apple's
/// Translation languages are written in, plus a few neighbours (Gurmukhi,
/// Bengali, Tamil…) that must be recognised precisely so they are *never*
/// mistaken for a translatable one. Everything else is `.other`.
public enum Script: String, CaseIterable, Equatable {
    case latin, greek, cyrillic, hebrew, arabic, devanagari, bengali, gurmukhi, tamil, thai, hangul, kana, han, other
}

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
            if script(of: scalar) == .devanagari {
                devanagari += 1
            }
        }
        return letters > 0 && devanagari * 10 >= letters * 3
    }

    /// True when the text's letters are predominantly Latin — used to verify
    /// a translation actually came back as English rather than model garbage
    /// (the hi→en model emits mangled output for scripts it can't read).
    public static func isMostlyLatin(_ text: String) -> Bool {
        var latin = 0
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if script(of: scalar) == .latin {
                latin += 1
            }
        }
        return letters > 0 && latin * 10 >= letters * 7
    }

    /// Script with the most alphabetic scalars; nil when the text has no letters.
    /// Any Hiragana/Katakana letter makes the result .kana (Chinese text never
    /// contains kana; Japanese text is usually kanji-heavy) — so Han vs
    /// Japanese is decided by a rule, not a model.
    public static func dominantScript(_ text: String) -> Script? {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            counts[script(of: scalar), default: 0] += 1
        }
        if counts[.kana] != nil {
            return .kana
        }
        var best: Script?
        var bestCount = 0
        // Strict `>`: a tie goes to the earlier case, so the answer is deterministic.
        for script in Script.allCases {
            if let count = counts[script], count > bestCount {
                best = script
                bestCount = count
            }
        }
        return best
    }

    /// Block-range lookup. Only ever asked about alphabetic scalars, so the
    /// ranges can be coarse (whole Unicode blocks) without miscounting digits
    /// or punctuation.
    private static func script(of scalar: Unicode.Scalar) -> Script {
        switch scalar.value {
        // Basic Latin through IPA, plus Latin Extended Additional — the block
        // Vietnamese's stacked diacritics live in.
        case ..<0x0250, 0x1E00...0x1EFF: return .latin
        case 0x0370...0x03FF: return .greek
        case 0x0400...0x052F: return .cyrillic
        case 0x0590...0x05FF: return .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0900...0x097F: return .devanagari
        case 0x0980...0x09FF: return .bengali
        case 0x0A00...0x0A7F: return .gurmukhi
        case 0x0B80...0x0BFF: return .tamil
        case 0x0E00...0x0E7F: return .thai
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return .hangul
        case 0x3040...0x30FF, 0x31F0...0x31FF: return .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF: return .han
        default: return .other
        }
    }
}
