import Foundation

/// The lyrics-to-display-lines pipeline: once a track's synced lyrics are in
/// hand, decides what the engine shows — the cached translation if there is
/// one, else which lines go to which on-device model and how their answers
/// are merged back. Pure: the caller reads/writes the cache file and runs the
/// translator; every rule that has ever gone wrong in between lives here.
public enum DisplayLines {
    public struct Config: Equatable {
        public let sources: Set<String>  // catalog ids lyrics may be translated from
        public let target: String        // catalog id they are translated into

        public init(sources: Set<String>, target: String) {
            self.sources = sources
            self.target = target
        }
    }

    public enum Plan: Equatable {
        case cached([LrcLine])  // replay: show these; neither the gate nor a model runs
        case translate(batches: [TranslationBatch], cacheKey: String)
        case nothing            // no line is translatable under this config
    }

    public struct Assembly: Equatable {
        public let display: [LrcLine]
        /// Sources whose pack exists but isn't downloaded — for the status row.
        public let skippedPacks: [String]
        /// Serialized `display`, present only when the result is worth freezing.
        public let cacheText: String?
    }

    /// Prefix on translated lines (monochrome, owner-requested). Baked into the
    /// cached text, so changing it means bumping `LanguageGate.cacheKeySuffix`.
    public static let marker = "⇄ "

    /// `lookup` returns the cached display text for a key (nil/empty = miss);
    /// `recognizer` is consulted by the gate only for scripts several enabled
    /// languages share. The cache is checked first: a replay must not run the
    /// recognizer again for lines already translated.
    public static func plan(lines: [LrcLine], config: Config, trackKey: String,
                            lookup: (String) -> String?,
                            recognizer: (String, [String]) -> String?) -> Plan {
        let suffix = LanguageGate.cacheKeySuffix(enabledSources: config.sources, target: config.target)
        let key = trackKey + "|" + suffix
        if let cached = lookup(key), !cached.isEmpty {
            return .cached(LrcParser.parse(cached))
        }
        let batches = LanguageGate.plan(
            lines: lines.map(\.text), enabledSources: config.sources, target: config.target,
            recognizer: recognizer)
        return batches.isEmpty ? .nothing : .translate(batches: batches, cacheKey: key)
    }

    /// Merges the batches' answers back onto the original lines. Only output
    /// that reads as the target language is accepted (bug #5: a model echoes
    /// garbage for scripts it can't read); timestamps are never touched.
    ///
    /// Cache policy: `cacheText` is set only when something was accepted and
    /// every outcome was deterministic. A missing pack or a transient failure
    /// still yields a partial `display` for this play, but is not frozen —
    /// the next play plans again, so downloading the pack later takes effect.
    public static func assemble(lines: [LrcLine], config: Config,
                                outcomes: [(batch: TranslationBatch, outcome: TranslateOutcome)]) -> Assembly {
        var display = lines
        var skipped: [String] = []
        var deterministic = true
        for (batch, outcome) in outcomes {
            switch outcome {
            case .translated(let texts):
                // A batch may answer fewer texts than asked; map the ones it has.
                for (j, index) in batch.indices.enumerated()
                where j < texts.count && index < lines.count
                    && LanguageGate.isPlausibleOutput(texts[j], target: config.target) {
                    display[index] = LrcLine(ms: lines[index].ms, text: marker + texts[j])
                }
            case .packNotDownloaded:
                skipped.append(batch.source)
                deterministic = false
            case .failed, .skipped:
                deterministic = false
            case .unsupported:
                break  // fixed for this macOS; caching it changes nothing
            }
        }
        let accepted = display != lines
        return Assembly(display: display, skippedPacks: skipped,
                        cacheText: accepted && deterministic ? LrcParser.serialize(display) : nil)
    }
}
