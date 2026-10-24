import Foundation

/// One synced-lyrics line: start time in milliseconds plus its text.
public struct LrcLine: Equatable {
    public let ms: Int
    public let text: String

    public init(ms: Int, text: String) {
        self.ms = ms
        self.text = text
    }
}

/// Parse LRC synced-lyrics text into `LrcLine`s sorted by start time.
public enum LrcParser {
    // Matches one timestamp like [mm:ss.xx], [mm:ss.xxx] or [mm:ss].
    // [0-9], not \d: ICU's \d also matches other scripts' digits (e.g.
    // Arabic-Indic), which Int() rejects — a community upload with such a
    // "timestamp" would otherwise crash the parse below.
    private static let timestamp = try! NSRegularExpression(
        pattern: #"\[([0-9]{1,2}):([0-9]{2})(?:\.([0-9]{1,3}))?\]"#)

    /// - Supports multiple timestamps on one line (line duplicated per timestamp).
    /// - Fractions of 1, 2, or 3 digits are interpreted as tenths/hundredths/ms.
    /// - Metadata tags ([ar:], [length:], etc.) and malformed lines are skipped.
    public static func parse(_ text: String) -> [LrcLine] {
        var out: [LrcLine] = []
        // Split on every newline form. NB: "\r\n" is a single grapheme in
        // Swift, so split(separator: "\n") silently fails to split CRLF files
        // (lrclib content arrives with whatever endings the uploader used).
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let stamps = timestamp.matches(
                in: line, range: NSRange(line.startIndex..., in: line))
            guard let last = stamps.last else { continue }
            // Lyric text is whatever follows the final timestamp.
            let lyricStart = Range(last.range, in: line)!.upperBound
            let lyric = String(line[lyricStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            for match in stamps {
                let minutes = Int(line[Range(match.range(at: 1), in: line)!])!
                let seconds = Int(line[Range(match.range(at: 2), in: line)!])!
                var ms = minutes * 60_000 + seconds * 1000
                if match.range(at: 3).location != NSNotFound {
                    let frac = String(line[Range(match.range(at: 3), in: line)!])
                    // Right-pad so ".5" means 500 ms and ".34" means 340 ms.
                    ms += Int(frac.padding(toLength: 3, withPad: "0", startingAt: 0))!
                }
                out.append(LrcLine(ms: ms, text: lyric))
            }
        }
        // Index tiebreak: Swift's sort is not documented stable, and equal-ms
        // lines must keep file order for deterministic output.
        return out.enumerated()
            .sorted { ($0.element.ms, $0.offset) < ($1.element.ms, $1.offset) }
            .map(\.element)
    }

    /// Inverse of parse — used to persist derived lyrics (e.g. translations)
    /// in the same cache format the app already reads.
    public static func serialize(_ lines: [LrcLine]) -> String {
        lines.map { line in
            String(format: "[%02d:%02d.%03d] %@",
                   line.ms / 60_000, (line.ms % 60_000) / 1000, line.ms % 1000, line.text)
        }.joined(separator: "\n")
    }
}
