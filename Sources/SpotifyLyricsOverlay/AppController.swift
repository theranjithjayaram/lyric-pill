import AppKit
import LyricsCore

/// Wires watcher → lyrics fetch → timing engine → overlay, entirely on the
/// main thread (lyrics fetches hop to a background queue and back).
///
/// Battery discipline: there is no periodic tick. While playing, a one-shot
/// timer is armed for exactly the next lyric-line boundary, and a slow (10 s)
/// resync timer corrects interpolation drift. Paused, stopped, Spotify closed,
/// or mode off ⇒ both timers are torn down and the process is fully idle until
/// Spotify's distributed notification wakes it.
final class AppController {
    private let engine = TimingEngine()
    private let watcher = SpotifyWatcher()
    private let overlay: OverlayWindow
    private let statusBar: StatusItemController
    private let lrclib: LrclibClient
    private let fetchQueue = DispatchQueue(label: "lyrics-fetch", qos: .utility)

    private var mode = Settings.mode
    private var moveMode = false
    private var playing = false
    private var hasLyrics = false
    private var fetching = false
    private var serviceUnreachable = false
    private var currentTrackId = ""
    private var currentSnapshot: SpotifyWatcher.Snapshot?
    // Bumped per track so an in-flight fetch for a previous track is ignored.
    private var trackGen = 0

    private var lineTimer: Timer?    // one-shot, fires at the next line boundary
    private var resyncTimer: Timer?  // repeating, only while playing
    private var retryTimer: Timer?   // one-shot backoff, only after a failed fetch
    private var retryDelay: TimeInterval = AppController.retryBaseDelay

    private let simulateLrcPath: String?

    private static let resyncInterval: TimeInterval = 10
    private static let retryBaseDelay: TimeInterval = 20
    private static let retryMaxDelay: TimeInterval = 300

    init(simulateLrcPath: String?) {
        self.simulateLrcPath = simulateLrcPath
        overlay = OverlayWindow(savedCenter: Settings.savedCenter)
        statusBar = StatusItemController(currentMode: mode)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        lrclib = LrclibClient(cacheDir: caches.appendingPathComponent("spotify-lyrics-overlay"))
    }

    func start() {
        overlay.onMoved = { Settings.savedCenter = $0 }

        statusBar.onModeChange = { [weak self] newMode in
            guard let self else { return }
            self.mode = newMode
            Settings.mode = newMode
            self.updateTimers()
            self.render()
        }
        statusBar.onMoveModeChange = { [weak self] enabled in
            guard let self else { return }
            self.moveMode = enabled
            self.overlay.setMoveMode(enabled)
            if !enabled {
                self.render()
            }
        }
        statusBar.statusText = { [weak self] in self?.statusDescription() ?? "" }

        if let path = simulateLrcPath {
            startSimulation(lrcPath: path)
            return
        }

        watcher.onSnapshot = { [weak self] snapshot in self?.apply(snapshot) }
        watcher.onPlayerGone = { [weak self] in self?.playerGone() }
        watcher.start()
        watcher.refresh()  // pick up an already-playing track at launch
    }

    // MARK: - Spotify events

    private func apply(_ snapshot: SpotifyWatcher.Snapshot) {
        currentSnapshot = snapshot
        if snapshot.trackId != currentTrackId {
            currentTrackId = snapshot.trackId
            startLyricsFetch(for: snapshot)
        }
        playing = snapshot.playing
        engine.seek(toMs: snapshot.positionMs)
        engine.setPlaying(snapshot.playing)
        // A resume can arrive while a service-down retry sits cancelled (we
        // don't retry while paused) — re-arm it.
        if playing, serviceUnreachable, !fetching, retryTimer == nil {
            scheduleLyricsRetry()
        }
        updateTimers()
        render()
    }

    private func playerGone() {
        playing = false
        hasLyrics = false
        fetching = false
        serviceUnreachable = false
        currentTrackId = ""
        currentSnapshot = nil
        retryTimer?.invalidate()
        retryTimer = nil
        engine.setLines([])
        engine.setPlaying(false)
        updateTimers()
        render()
    }

    // MARK: - Lyrics

    private func startLyricsFetch(for snapshot: SpotifyWatcher.Snapshot) {
        trackGen += 1
        hasLyrics = false
        serviceUnreachable = false
        retryTimer?.invalidate()
        retryTimer = nil
        retryDelay = Self.retryBaseDelay
        engine.setLines([])
        guard !snapshot.trackId.isEmpty, !snapshot.title.isEmpty else {
            fetching = false
            return
        }
        dispatchFetch(gen: trackGen, snapshot: snapshot)
    }

    private func dispatchFetch(gen: Int, snapshot: SpotifyWatcher.Snapshot) {
        fetching = true
        fetchQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.lrclib.getSynced(
                artist: snapshot.artist, title: snapshot.title,
                album: snapshot.album, durationS: snapshot.durationMs / 1000)
            DispatchQueue.main.async {
                self.applyLyrics(gen: gen, outcome: outcome)
            }
        }
    }

    private func applyLyrics(gen: Int, outcome: LyricsOutcome) {
        guard gen == trackGen else { return }  // a newer track superseded this fetch
        fetching = false
        switch outcome {
        case .found(let lrc):
            engine.setLines(LrcParser.parse(lrc))
            hasLyrics = true
            serviceUnreachable = false
        case .none:
            engine.setLines([])
            hasLyrics = false
            serviceUnreachable = false
        case .unavailable:
            engine.setLines([])
            hasLyrics = false
            serviceUnreachable = true
            if playing {
                scheduleLyricsRetry()
            }
        }
        // Re-sync position now that lyrics are ready (covers the fetch delay).
        watcher.refresh()
        updateTimers()
        render()
    }

    /// lrclib being down must not blank the whole song: back off and retry
    /// while this track keeps playing. Paused/stopped ⇒ no timer (idle
    /// discipline holds); apply() re-arms the retry on resume.
    private func scheduleLyricsRetry() {
        retryTimer?.invalidate()
        let gen = trackGen
        let timer = Timer(timeInterval: retryDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.retryTimer = nil
            guard gen == self.trackGen, self.playing, self.serviceUnreachable,
                  let snapshot = self.currentSnapshot else { return }
            self.retryDelay = min(self.retryDelay * 2, Self.retryMaxDelay)
            self.dispatchFetch(gen: gen, snapshot: snapshot)
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: - Scheduling

    private func updateTimers() {
        scheduleLineTimer()

        let wantResync = playing && simulateLrcPath == nil
        if wantResync, resyncTimer == nil {
            let timer = Timer(timeInterval: Self.resyncInterval, repeats: true) { [weak self] _ in
                self?.watcher.refresh()
            }
            timer.tolerance = 1  // let the kernel coalesce wakeups
            RunLoop.main.add(timer, forMode: .common)
            resyncTimer = timer
        } else if !wantResync {
            resyncTimer?.invalidate()
            resyncTimer = nil
        }
    }

    private func scheduleLineTimer() {
        lineTimer?.invalidate()
        lineTimer = nil
        guard playing, hasLyrics, mode != .off,
              let nextMs = engine.nextBoundaryMs() else { return }
        // Small lead so we land just past the boundary, never just before it.
        let delay = max(0.05, Double(nextMs - engine.positionMs()) / 1000.0 + 0.02)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.render()
            self?.scheduleLineTimer()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        lineTimer = timer
    }

    // MARK: - Rendering

    private func render() {
        if moveMode {
            return  // don't fight the drag
        }
        let line = hasLyrics ? engine.currentText() : ""
        let show: Bool
        switch mode {
        case .off:
            show = false
        case .on:
            show = !line.isEmpty
        case .auto:
            show = playing && hasLyrics && !line.isEmpty
        }
        if show {
            overlay.setText(line)
            overlay.show()
        } else {
            overlay.hide()
        }
    }

    private func statusDescription() -> String {
        if simulateLrcPath != nil { return "Simulating local lyrics" }
        if !watcher.isSpotifyRunning { return "Spotify is not running" }
        if let error = watcher.lastError { return "Spotify: \(error)" }
        if currentTrackId.isEmpty { return "Nothing playing" }
        if fetching { return "Fetching lyrics…" }
        if serviceUnreachable { return "Lyrics service (lrclib.net) unreachable — retrying" }
        if !hasLyrics { return "No synced lyrics for this track" }
        return playing ? "Showing synced lyrics" : "Paused"
    }

    // MARK: - Simulation (debug: drive the overlay from a local .lrc file)

    private func startSimulation(lrcPath: String) {
        guard let text = try? String(contentsOfFile: lrcPath, encoding: .utf8) else {
            FileHandle.standardError.write(Data("cannot read \(lrcPath)\n".utf8))
            NSApp.terminate(nil)
            return
        }
        engine.setLines(LrcParser.parse(text))
        hasLyrics = true
        playing = true
        engine.seek(toMs: 0)
        engine.setPlaying(true)
        updateTimers()
        render()
    }
}
