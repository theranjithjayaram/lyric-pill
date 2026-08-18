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
    // Bumped per track so an in-flight fetch for a previous track is ignored.
    private var trackGen = 0

    private var lineTimer: Timer?    // one-shot, fires at the next line boundary
    private var resyncTimer: Timer?  // repeating, only while playing

    private let simulateLrcPath: String?

    private static let resyncInterval: TimeInterval = 10

    private let cacheDir: URL
    // Type-erased because LyricsTranslator is macOS 15+ while the app targets 13.
    private var translatorStorage: Any?
    private var currentFetchKey = ""

    init(simulateLrcPath: String?) {
        self.simulateLrcPath = simulateLrcPath
        overlay = OverlayWindow(savedCenter: Settings.savedCenter)
        statusBar = StatusItemController(currentMode: mode, translateHindi: Settings.translateHindi)
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spotify-lyrics-overlay")
        lrclib = LrclibClient(cacheDir: cacheDir)
    }

    @available(macOS 15.0, *)
    private var translator: LyricsTranslator {
        if let existing = translatorStorage as? LyricsTranslator {
            return existing
        }
        let created = LyricsTranslator()
        translatorStorage = created
        return created
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
        statusBar.onTranslateChange = { [weak self] enabled in
            guard let self else { return }
            Settings.translateHindi = enabled
            // Re-run the current track through the (cached) fetch so the
            // toggle takes effect immediately, not at the next song.
            self.currentTrackId = ""
            self.watcher.refresh()
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
        if snapshot.trackId != currentTrackId {
            currentTrackId = snapshot.trackId
            startLyricsFetch(for: snapshot)
        }
        playing = snapshot.playing
        engine.seek(toMs: snapshot.positionMs)
        engine.setPlaying(snapshot.playing)
        updateTimers()
        render()
    }

    private func playerGone() {
        playing = false
        hasLyrics = false
        fetching = false
        serviceUnreachable = false
        currentTrackId = ""
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
        engine.setLines([])
        currentFetchKey = [snapshot.artist, snapshot.title, snapshot.album,
                           String(snapshot.durationMs / 1000)].joined(separator: "|")
        guard !snapshot.trackId.isEmpty, !snapshot.title.isEmpty else {
            fetching = false
            return
        }
        fetching = true
        let gen = trackGen
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
            let lines = LrcParser.parse(lrc)
            engine.setLines(lines)
            hasLyrics = true
            serviceUnreachable = false
            translateIfNeeded(gen: gen, lines: lines)
        case .none:
            engine.setLines([])
            hasLyrics = false
            serviceUnreachable = false
        case .unavailable:
            // Deliberately no retry loop: this song simply goes without lyrics
            // (nothing is cached, so the next track/replay fetches fresh). The
            // menu status tells the truth about why.
            engine.setLines([])
            hasLyrics = false
            serviceUnreachable = true
        }
        // Re-sync position now that lyrics are ready (covers the fetch delay).
        watcher.refresh()
        updateTimers()
        render()
    }

    // MARK: - Translation (Devanagari-script lyrics → English, on-device)

    private func translateIfNeeded(gen: Int, lines: [LrcLine]) {
        guard Settings.translateHindi, #available(macOS 15.0, *) else { return }
        guard ScriptDetector.isMostlyDevanagari(lines.map(\.text).joined(separator: " "))
        else { return }

        let cachePath = cacheDir.appendingPathComponent(
            LrclibClient.cacheDigest(currentFetchKey + "|hi-en") + ".lrc")
        if let cached = try? String(contentsOf: cachePath, encoding: .utf8), !cached.isEmpty {
            engine.setLines(Self.markTranslated(LrcParser.parse(cached)))
            updateTimers()
            render()
            return
        }

        // Original lines stay on screen while the translation runs (~1-2 s);
        // timestamps are preserved, only the text is swapped.
        translator.translate(lines: lines.map(\.text)) { [weak self] translated in
            guard let self, gen == self.trackGen, let translated else { return }
            let translatedLines = zip(lines, translated).map { LrcLine(ms: $0.ms, text: $1) }
            self.engine.setLines(Self.markTranslated(translatedLines))
            // Cache stays unmarked — the marker is display-only.
            try? Data(LrcParser.serialize(translatedLines).utf8)
                .write(to: cachePath, options: .atomic)
            self.updateTimers()
            self.render()
        }
    }

    /// Monochrome marker so the user can tell translated lines from lrclib
    /// originals at a glance; interlude (empty) lines stay unmarked.
    private static func markTranslated(_ lines: [LrcLine]) -> [LrcLine] {
        lines.map { $0.text.isEmpty ? $0 : LrcLine(ms: $0.ms, text: "⇄ " + $0.text) }
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
        if serviceUnreachable { return "Lyrics server unreachable" }
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
