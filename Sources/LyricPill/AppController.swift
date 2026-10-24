import AppKit
import Combine
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
    /// Where the current track's lyrics stand — the renderer shows lines only
    /// for `.found`, the status row names every other state.
    private enum LyricsState {
        case idle         // nothing playing, or a track with no identity to look up
        case fetching
        case found
        case none         // definitive: lrclib has no synced lyrics for this track
        case unavailable  // couldn't ask lrclib — never cached, never retried
    }

    private let store = SettingsStore.shared
    private let engine = TimingEngine()
    private let watcher = SpotifyWatcher()
    private let overlay: OverlayWindow
    private let statusBar: StatusItemController
    private let lrclib: LrclibClient
    private let fetchQueue = DispatchQueue(label: "lyrics-fetch", qos: .utility)

    private var moveMode = false
    private var lyrics: LyricsState = .idle
    private var currentTrackId = ""
    // Bumped per track so an in-flight fetch for a previous track is ignored.
    private var trackGen = 0
    // Source ids whose language pack exists but isn't downloaded — the status
    // row points the user at Settings instead of translating silently nothing.
    private var translationSkippedPacks: [String] = []

    private var lineTimer: Timer?    // one-shot, fires at the next line boundary
    private var resyncTimer: Timer?  // repeating, only while playing

    private var subscriptions = Set<AnyCancellable>()
    private var settingsWindow: SettingsWindowController?  // built on first open

    private let simulateLrcPath: String?
    private let showSettingsAtStart: SettingsTab?  // debug: `--settings [tab]`

    private static let resyncInterval: TimeInterval = 10

    // Type-erased because LyricsTranslator is macOS 15+ while the app targets 13.
    private var translatorStorage: Any?
    private var currentFetchKey = ""

    init(simulateLrcPath: String?, showSettingsAtStart: SettingsTab?) {
        self.simulateLrcPath = simulateLrcPath
        self.showSettingsAtStart = showSettingsAtStart
        let overlay = OverlayWindow(savedCenter: store.savedCenter)
        overlay.setStyle(fontSize: store.pillFontSize, opacity: store.pillOpacity)
        self.overlay = overlay
        statusBar = StatusItemController()
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyric-pill")
        lrclib = LrclibClient(cacheDir: cacheDir,
                              httpGet: LrclibClient.defaultHttpGet(userAgent: AppInfo.userAgent))
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
        overlay.onMoved = { [store] in store.savedCenter = $0 }
        observeSettings()

        statusBar.onMoveModeChange = { [weak self] enabled in
            guard let self else { return }
            self.moveMode = enabled
            self.overlay.setMoveMode(enabled)
            if !enabled {
                self.render()
            }
        }
        statusBar.onOpenSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        statusBar.statusText = { [weak self] in self?.statusDescription() ?? "" }

        // Both opens wait for app.run(), so the window appears the way a menu
        // click would open it rather than before the app has launched.
        if let tab = showSettingsAtStart {
            DispatchQueue.main.async { [weak self] in self?.showSettings(tab: tab) }
        } else if !store.firstRunDone {
            // One-shot welcome: let the status item land, then open Settings.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.store.firstRunDone = true
                self.showSettings(tab: .general)
            }
        }

        if let path = simulateLrcPath {
            startSimulation(lrcPath: path)
            return
        }

        watcher.onSnapshot = { [weak self] snapshot in self?.apply(snapshot) }
        watcher.onPlayerGone = { [weak self] in self?.playerGone() }
        watcher.start()
        watcher.refresh()  // pick up an already-playing track at launch
    }

    // MARK: - Settings

    /// Changes arrive from the menu and the Settings window alike. @Published
    /// fires on willSet, so every sink hops to the next run-loop pass and reads
    /// the store's settled value.
    private func observeSettings() {
        store.$mode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.updateTimers()
            self.render()
        }.store(in: &subscriptions)

        Publishers.CombineLatest(store.$pillFontSize, store.$pillOpacity).dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.overlay.setStyle(fontSize: self.store.pillFontSize, opacity: self.store.pillOpacity)
            }.store(in: &subscriptions)

        Publishers.Merge3(store.$translateEnabled.dropFirst().map { _ in () },
                          store.$translateSources.dropFirst().map { _ in () },
                          store.$translateTarget.dropFirst().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                // Re-run the current track through the (cached) fetch so the
                // change takes effect immediately, not at the next song.
                self.currentTrackId = ""
                self.watcher.refresh()
            }.store(in: &subscriptions)
    }

    private func showSettings(tab: SettingsTab) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(services: settingsServices())
        }
        settingsWindow?.show(tab: tab)
    }

    private func settingsServices() -> SettingsServices {
        var services = SettingsServices(
            resetPillPosition: { [weak self] in self?.overlay.resetPosition() },
            translation: nil)
        if #available(macOS 15.0, *) {
            // `translator` is resolved inside each closure, so its host window
            // is created on first use — not just because Settings opened.
            services.translation = SettingsServices.Translation(
                supportedLanguageIDs: { [weak self] in
                    await self?.translator.supportedLanguageIDs() ?? []
                },
                packStatus: { [weak self] source, target in
                    await self?.translator.availability(from: source, to: target) ?? .unsupported
                },
                downloadPack: { [weak self] source, target, completion in
                    guard let self else { return completion(false) }
                    self.translator.downloadLanguagePack(from: source, to: target, completion: completion)
                })
        }
        return services
    }

    // MARK: - Spotify events

    private func apply(_ snapshot: SpotifyWatcher.Snapshot) {
        if snapshot.trackId != currentTrackId {
            currentTrackId = snapshot.trackId
            startLyricsFetch(for: snapshot)
        }
        engine.seek(toMs: snapshot.positionMs)
        engine.setPlaying(snapshot.playing)
        updateTimers()
        render()
    }

    private func playerGone() {
        resetLyrics(to: .idle)
        currentTrackId = ""
        engine.setPlaying(false)
        updateTimers()
        render()
    }

    // MARK: - Lyrics

    /// Drops everything the previous track's lyrics left behind.
    private func resetLyrics(to state: LyricsState) {
        lyrics = state
        translationSkippedPacks = []
        engine.setLines([])
    }

    private func startLyricsFetch(for snapshot: SpotifyWatcher.Snapshot) {
        trackGen += 1
        currentFetchKey = LrclibClient.cacheKey(
            artist: snapshot.artist, title: snapshot.title, album: snapshot.album,
            durationS: snapshot.durationMs / 1000)
        guard !snapshot.trackId.isEmpty, !snapshot.title.isEmpty else {
            resetLyrics(to: .idle)
            return
        }
        resetLyrics(to: .fetching)
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
        switch outcome {
        case .found(let lrc):
            let lines = LrcParser.parse(lrc)
            engine.setLines(lines)
            lyrics = .found
            translateIfNeeded(gen: gen, lines: lines)
        case .none:
            engine.setLines([])
            lyrics = .none
        case .unavailable:
            // Deliberately no retry loop: this song simply goes without lyrics
            // (nothing is cached, so the next track/replay fetches fresh). The
            // menu status tells the truth about why.
            engine.setLines([])
            lyrics = .unavailable
        }
        // Re-sync position now that lyrics are ready (covers the fetch delay).
        watcher.refresh()
        updateTimers()
        render()
    }

    // MARK: - Translation (the display-lines pipeline decides; this runs it)

    private func translateIfNeeded(gen: Int, lines: [LrcLine]) {
        guard store.translateEnabled, #available(macOS 15.0, *) else { return }
        let config = DisplayLines.Config(sources: Set(store.translateSources), target: store.translateTarget)
        // The display cache is a sibling file of the track's lyrics in
        // lrclib's directory; the pipeline composes the key, we do the I/O.
        let plan = DisplayLines.plan(
            lines: lines, config: config, trackKey: currentFetchKey,
            lookup: { try? String(contentsOf: lrclib.cachePath(for: $0), encoding: .utf8) },
            recognizer: AppleLanguageRecognizer.recognize)
        switch plan {
        case .cached(let display):
            setDisplayLines(display)
        case .nothing:
            break
        case .translate(let batches, let cacheKey):
            // All batches go on the translator's FIFO at once; the originals
            // stay on screen until the last answer, then the result commits.
            var outcomes: [(batch: TranslationBatch, outcome: TranslateOutcome)] = []
            for batch in batches {
                translator.translate(lines: batch.indices.map { lines[$0].text },
                                     from: batch.source, to: config.target,
                                     skipIf: { [weak self] in gen != self?.trackGen }) { [weak self] outcome in
                    outcomes.append((batch, outcome))
                    guard let self, outcomes.count == batches.count, gen == self.trackGen else { return }
                    let result = DisplayLines.assemble(lines: lines, config: config, outcomes: outcomes)
                    self.translationSkippedPacks = result.skippedPacks  // status row
                    if let text = result.cacheText {
                        try? Data(text.utf8).write(to: self.lrclib.cachePath(for: cacheKey), options: .atomic)
                    }
                    // A partial result (missing pack, transient failure) is
                    // still shown this play; it just isn't frozen.
                    if result.display != lines {
                        self.setDisplayLines(result.display)
                    }
                }
            }
        }
    }

    private func setDisplayLines(_ display: [LrcLine]) {
        engine.setLines(display)
        updateTimers()
        render()
    }

    // MARK: - Scheduling

    private func updateTimers() {
        scheduleLineTimer()

        let wantResync = engine.isPlaying && simulateLrcPath == nil
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
        guard engine.isPlaying, lyrics == .found, store.mode != .off,
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
        let line = lyrics == .found ? engine.currentText() : ""
        let show: Bool
        switch store.mode {
        case .off:
            show = false
        case .on:
            show = !line.isEmpty
        case .auto:
            show = engine.isPlaying && lyrics == .found && !line.isEmpty
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
        switch lyrics {
        case .fetching: return "Fetching lyrics…"
        case .unavailable: return "Lyrics server unreachable"
        case .idle, .none: return "No synced lyrics for this track"
        case .found: break
        }
        let showing = engine.isPlaying ? "Showing synced lyrics" : "Paused"
        guard !translationSkippedPacks.isEmpty else { return showing }
        let names = translationSkippedPacks.map(TranslationCatalog.name(for:)).joined(separator: ", ")
        return "\(showing) — \(names) pack not downloaded (Settings → Translation)"
    }

    // MARK: - Simulation (debug: drive the overlay from a local .lrc file)

    private func startSimulation(lrcPath: String) {
        guard let text = try? String(contentsOfFile: lrcPath, encoding: .utf8) else {
            warn("cannot read \(lrcPath)")
            exit(1)
        }
        engine.setLines(LrcParser.parse(text))
        lyrics = .found
        engine.seek(toMs: 0)
        engine.setPlaying(true)
        updateTimers()
        render()
    }
}
