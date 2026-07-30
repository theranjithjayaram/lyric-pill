import Foundation

/// Interpolates playback position between authoritative samples and picks the
/// active lyric line. Clock is injectable for tests; the default is monotonic
/// (does not jump with wall-clock changes).
public final class TimingEngine {
    private let clock: () -> Double     // seconds
    private var lines: [LrcLine] = []
    private var baseMs = 0              // last authoritative position sample
    private var ref: Double             // clock() when baseMs was captured
    private var playing = false

    public init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.ref = clock()
    }

    public func setLines(_ newLines: [LrcLine]) {
        lines = newLines
    }

    /// Record an authoritative position sample (milliseconds).
    public func seek(toMs ms: Int) {
        baseMs = max(0, ms)
        ref = clock()
    }

    public func setPlaying(_ nowPlaying: Bool) {
        // Re-base so the frozen/elapsed math stays correct across transitions.
        baseMs = positionMs()
        ref = clock()
        playing = nowPlaying
    }

    public var isPlaying: Bool { playing }

    public func positionMs() -> Int {
        playing ? baseMs + Int((clock() - ref) * 1000.0) : baseMs
    }

    /// Index of the greatest line start <= position, or -1 if before all lines.
    public func currentIndex() -> Int {
        let pos = positionMs()
        var lo = 0
        var hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].ms <= pos { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    public func currentText() -> String {
        let i = currentIndex()
        return i >= 0 ? lines[i].text : ""
    }

    /// Start time (ms) of the line after the current one, or nil when on the
    /// last line (or there are no lines). Lets the app sleep until exactly the
    /// next line change instead of ticking on an interval.
    public func nextBoundaryMs() -> Int? {
        let next = currentIndex() + 1
        return next < lines.count ? lines[next].ms : nil
    }
}
