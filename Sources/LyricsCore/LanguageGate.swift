import Foundation

/// The lines of one source language, to be sent to the translator together.
public struct TranslationBatch: Equatable {
    public let source: String      // catalog id
    public let indices: [Int]      // ascending line indices

    public init(source: String, indices: [Int]) {
        self.source = source
        self.indices = indices
    }
}

/// The per-line translation gate, generalised from "Devanagari → hi".
///
/// Rule-based and deterministic: a line is translated only when its script
/// belongs to exactly one enabled language, or when a recognizer — consulted
/// solely for scripts several enabled languages share — picks one of them.
/// Sending a line to the wrong model yields cached garbage (bug #5), so every
/// doubt resolves to "leave the line alone".
public enum LanguageGate {
    /// Decides, per line, which enabled source language (if any) it should be translated from.
    /// `recognizer(text, constraints)` returns one of `constraints` or nil; it is consulted ONLY when a
    /// script maps to more than one candidate (e.g. Cyrillic → ru/uk, Latin → fr/es…).
    ///
    /// Rules, in order, for each line:
    /// 1. sources = enabledSources ∩ catalog ids, minus the target.
    /// 2. script = dominantScript(line); no letters (empty, numbers, "…") → skip.
    /// 3. candidates = catalog languages written in that script ∩ sources,
    ///    in catalog order; none → skip.
    /// 4. script == target's script (e.g. a Latin line with Spanish enabled and
    ///    English as target — it may already *be* English): ask the recognizer
    ///    with the target appended as a sink; translate only if it names a
    ///    candidate (target or nil → skip).
    /// 5. Exactly one candidate → that one, no recognizer.
    /// 6. Several → the recognizer must name one of them, else skip.
    /// Batches come back sorted by source id, indices ascending.
    public static func plan(lines: [String], enabledSources: Set<String>, target: String,
                            recognizer: (String, [String]) -> String?) -> [TranslationBatch] {
        let sources = sources(enabled: enabledSources, target: target)
        // An unknown target can't be validated (isPlausibleOutput) — translate nothing.
        guard !sources.isEmpty,
              let targetScript = TranslationCatalog.language(for: target)?.script
        else { return [] }

        var indicesBySource: [String: [Int]] = [:]
        for (index, line) in lines.enumerated() {
            guard let script = ScriptDetector.dominantScript(line) else { continue }
            let candidates = TranslationCatalog.candidates(for: script).filter(sources.contains)
            guard !candidates.isEmpty else { continue }

            let source: String?
            if script == targetScript {
                source = pick(recognizer(line, candidates + [target]), from: candidates)
            } else if candidates.count == 1 {
                source = candidates[0]
            } else {
                source = pick(recognizer(line, candidates), from: candidates)
            }
            if let source {
                indicesBySource[source, default: []].append(index)
            }
        }
        return indicesBySource.keys.sorted().map {
            TranslationBatch(source: $0, indices: indicesBySource[$0]!)
        }
    }

    /// Translated text must come back in the target language's script (the models emit garbage for scripts they cannot read).
    public static func isPlausibleOutput(_ text: String, target: String) -> Bool {
        guard let targetScript = TranslationCatalog.language(for: target)?.script else { return false }
        // dominantScript is nil for empty/letterless text, so that fails too.
        return ScriptDetector.dominantScript(text) == targetScript
    }

    /// Cache-key suffix that changes whenever the translation configuration changes, e.g. "tr-en-hi,ru-v3".
    /// Built from the *effective* sources (rule 1), so toggling a language that
    /// can't take part (the target itself, an unknown id) doesn't invalidate
    /// anything. "-v3" follows "hi-en-v2": bump it to abandon poisoned entries.
    public static func cacheKeySuffix(enabledSources: Set<String>, target: String) -> String {
        let sources = sources(enabled: enabledSources, target: target).sorted()
        return "tr-" + target + "-" + sources.joined(separator: ",") + "-v3"
    }

    /// enabled ∩ catalog, minus the target: the languages a line can actually
    /// be translated from.
    private static func sources(enabled: Set<String>, target: String) -> Set<String> {
        enabled.filter { $0 != target && TranslationCatalog.language(for: $0) != nil }
    }

    /// The recognizer's answer, accepted only when it is one of `candidates`
    /// (so the target sink, nil, or any stray value all mean "skip").
    private static func pick(_ answer: String?, from candidates: [String]) -> String? {
        guard let answer, candidates.contains(answer) else { return nil }
        return answer
    }
}
