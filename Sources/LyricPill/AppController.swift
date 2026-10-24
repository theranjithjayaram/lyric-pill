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
    private let store = SettingsStore.shared
    private let engine = TimingEngine()
    private let watcher = SpotifyWatcher()
    private let overlay: OverlayWindow
    private let statusBar: StatusItemController
    private let lrclib: LrclibClient
    private let fetchQueue = DispatchQueue(label: "lyrics-fetch", qos: .utility)

    private var mode: OverlayMode
    private var moveMode = false
    private var playing = false
    private var hasLyrics = false
    private var fetching = false
    private var serviceUnreachable = false
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
    private let showSettingsAtStart: Bool

    private static let resyncInterval: TimeInterval = 10

    private let cacheDir: URL
    // Type-erased because LyricsTranslator is macOS 15+ while the app targets 13.
    private var translatorStorage: Any?
    private var currentFetchKey = ""

    init(simulateLrcPath: String?, showSettingsAtStart: Bool) {
        self.simulateLrcPath = simulateLrcPath
        self.showSettingsAtStart = showSettingsAtStart
        mode = store.mode
        let overlay = OverlayWindow(savedCenter: store.savedCenter)
        overlay.setStyle(fontSize: store.pillFontSize, opacity: store.pillOpacity)
        self.overlay = overlay
        statusBar = StatusItemController()
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lyric-pill")
        lrclib = LrclibClient(cacheDir: cacheDir, appVersion: AppInfo.version)
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
        if showSettingsAtStart {
            DispatchQueue.main.async { [weak self] in self?.showSettings(tab: .general) }
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
    /// fires on willSet, so the sinks use the delivered values (or defer)
    /// rather than reading the store back.
    private func observeSettings() {
        store.$mode.dropFirst().sink { [weak self] newMode in
            guard let self else { return }
            self.mode = newMode
            self.updateTimers()
            self.render()
        }.store(in: &subscriptions)

        Publishers.CombineLatest(store.$pillFontSize, store.$pillOpacity).dropFirst()
            .sink { [weak self] size, opacity in
                self?.overlay.setStyle(fontSize: size, opacity: opacity)
            }.store(in: &subscriptions)

        Publishers.Merge3(store.$translateEnabled.dropFirst().map { _ in () },
                          store.$translateSources.dropFirst().map { _ in () },
                          store.$translateTarget.dropFirst().map { _ in () })
            .receive(on: DispatchQueue.main)  // after the store has the new value
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
            let translator = self.translator
            services.translation = SettingsServices.Translation(
                supportedLanguageIDs: { await translator.supportedLanguageIDs() },
                packStatus: { source, target in
                    switch await translator.availability(from: source, to: target) {
                    case .installed: .installed
                    case .supported: .downloadable
                    default: .unsupported
                    }
                },
                downloadPack: { source, target, completion in
                    translator.downloadLanguagePack(from: source, to: target, completion: completion)
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
        translationSkippedPacks = []
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
        translationSkippedPacks = []
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

    // MARK: - Translation (per-line language gate → on-device models)

    private func translateIfNeeded(gen: Int, lines: [LrcLine]) {
        guard store.translateEnabled, #available(macOS 15.0, *) else { return }
        let target = store.translateTarget
        let sources = Set(store.translateSources)
        // Per-line gate: uploads mix scripts (e.g. Hindi verses in Devanagari
        // with Punjabi hook lines in Gurmukhi) — each line goes only to the
        // model its own script (plus the recognizer, for shared scripts) names.
        let batches = LanguageGate.plan(
            lines: lines.map(\.text), enabledSources: sources, target: target,
            recognizer: AppleLanguageRecognizer.recognize)
        guard !batches.isEmpty else { return }

        // v3: display lines (with ⇄ markers baked in), keyed by the enabled
        // pairs — v1 cached raw model output unvalidated, v2 was hi→en only;
        // both are simply abandoned.
        let suffix = LanguageGate.cacheKeySuffix(enabledSources: sources, target: target)
        let cachePath = cacheDir.appendingPathComponent(
            LrclibClient.cacheDigest(currentFetchKey + "|" + suffix) + ".lrc")
        if let cached = try? String(contentsOf: cachePath, encoding: .utf8), !cached.isEmpty {
            engine.setLines(LrcParser.parse(cached))
            updateTimers()
            render()
            return
        }

        // Original lines stay on screen while the batches run (~1-2 s each);
        // timestamps are preserved, only accepted texts are swapped.
        runTranslation(batches: batches[...], target: target, gen: gen,
                       lines: lines, display: lines, cachePath: cachePath)
    }

    /// One batch at a time; `display` accumulates accepted lines until the
    /// last batch, which commits (cache + engine + render) if anything changed.
    @available(macOS 15.0, *)
    private func runTranslation(batches: ArraySlice<TranslationBatch>, target: String, gen: Int,
                                lines: [LrcLine], display: [LrcLine], cachePath: URL) {
        guard gen == trackGen else { return }
        guard let batch = batches.first else {
            guard display != lines else { return }  // nothing accepted — keep originals
            engine.setLines(display)
            try? Data(LrcParser.serialize(display).utf8).write(to: cachePath, options: .atomic)
            updateTimers()
            render()
            return
        }
        let rest = batches.dropFirst()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await self.translator.availability(from: batch.source, to: target)
            guard gen == self.trackGen else { return }
            // A pack that exists but isn't downloaded is never fetched from
            // here (no consent sheet mid-song): note it for the status row.
            guard status == .installed else {
                if status == .supported {
                    self.translationSkippedPacks.append(batch.source)
                }
                self.runTranslation(batches: rest, target: target, gen: gen,
                                    lines: lines, display: display, cachePath: cachePath)
                return
            }
            self.translator.translate(lines: batch.indices.map { lines[$0].text },
                                      from: batch.source, to: target) { [weak self] translated in
                guard let self else { return }
                var display = display
                for (j, index) in batch.indices.enumerated() where j < (translated?.count ?? 0) {
                    // Accept only output that reads as the target language;
                    // the marked line tells the user it's our translation.
                    if let text = translated?[j], LanguageGate.isPlausibleOutput(text, target: target) {
                        display[index] = LrcLine(ms: lines[index].ms, text: "⇄ " + text)
                    }
                }
                self.runTranslation(batches: rest, target: target, gen: gen,
                                    lines: lines, display: display, cachePath: cachePath)
            }
        }
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
        let showing = playing ? "Showing lyrics" : "Paused"
        if !translationSkippedPacks.isEmpty {
            let names = translationSkippedPacks
                .map { TranslationCatalog.language(for: $0)?.name ?? $0 }
                .joined(separator: ", ")
            return "\(showing) — \(names) pack not downloaded (Settings → Translation)"
        }
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
