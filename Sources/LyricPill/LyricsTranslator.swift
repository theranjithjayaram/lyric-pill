import AppKit
import LyricsCore
import SwiftUI
import Translation

/// One source→target pair's language-pack state, free of Translation-framework
/// types so macOS 13 code (the Settings view) can use it.
enum PackStatus {
    case installed, downloadable, unsupported
}

/// What a translate job came back with; the caller keeps its original lines
/// for anything but `.translated`.
enum TranslateOutcome {
    case translated([String])
    case packNotDownloaded  // the pair exists, its pack isn't on this Mac
    case unsupported
    case failed             // framework error, or the deadline
    case skipped            // the caller's `skipIf` said nobody wants the result
}

/// On-device translation of lyric lines via Apple's Translation framework
/// (macOS 15+), one source→target pair per job, jobs run one at a time in
/// order. The framework only hands out sessions through a SwiftUI
/// `.translationTask`, so a tiny host window carries one: invisible for
/// normal work, shown only for a language-pack download requested from
/// Settings (macOS presents its consent sheet on it).
// Main-thread-only by convention, like the rest of the app (no @MainActor:
// the annotation would make every nonisolated caller a hard error).
@available(macOS 15.0, *)
final class LyricsTranslator {
    private enum Work {
        case translate(lines: [String], skipIf: () -> Bool, completion: (TranslateOutcome) -> Void)
        case download((Bool) -> Void)
    }

    private enum JobResult {
        case translate(TranslateOutcome)
        case download(installed: Bool)
    }

    // A class, so the in-flight job has an identity: a late or duplicate
    // answer (a task SwiftUI cancelled, or one that fires after the deadline)
    // is told apart from the current job by `===`.
    private final class Job {
        let source: String  // catalog ids
        let target: String
        let work: Work

        init(source: String, target: String, work: Work) {
            self.source = source
            self.target = target
            self.work = work
        }
    }

    private final class Model: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
        @Published var message = "Preparing translation…"
        var job: (lines: [String], completion: ([String]?) -> Void)?
    }

    private struct HostView: View {
        @ObservedObject var model: Model

        var body: some View {
            Text(model.message)
                .padding(20)
                .translationTask(model.configuration) { session in
                    let job = await MainActor.run { () -> ([String], ([String]?) -> Void)? in
                        defer { model.job = nil }
                        return model.job
                    }
                    guard let (lines, completion) = job else { return }
                    do {
                        // No-op when the model is installed; otherwise presents
                        // the one-time download consent on the host window.
                        try await session.prepareTranslation()
                        let requests = lines.enumerated()
                            .filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
                            .map {
                                TranslationSession.Request(
                                    sourceText: $0.element, clientIdentifier: String($0.offset))
                            }
                        var out = lines
                        if !requests.isEmpty {  // a download job has nothing to translate
                            let responses = try await session.translations(from: requests)
                            for response in responses {
                                if let id = response.clientIdentifier, let i = Int(id), i < out.count {
                                    out[i] = response.targetText
                                }
                            }
                        }
                        let result = out
                        await MainActor.run { completion(result) }
                    } catch {
                        warn("translation failed: \(error)")
                        await MainActor.run { completion(nil) }
                    }
                }
        }
    }

    private let model = Model()
    private let window: NSWindow
    // FIFO: `current` is in flight, `queue` waits; the next starts when the
    // current completes — songs can change faster than a translation
    // finishes, and dropping the second request would silently skip that song.
    private var queue: [Job] = []
    private var current: Job?
    // A translate job that never answers (translationd wedged) would block
    // every later translation and pack download for the process lifetime, so
    // each one gets a single one-shot deadline — no repeating machinery.
    // Downloads wait on the user's consent sheet and have none.
    private static let translateTimeout: TimeInterval = 60

    init() {
        let hosting = NSHostingView(rootView: HostView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.contentView = hosting
        window.title = "Lyrics Translation"
        window.isReleasedWhenClosed = false
    }

    /// Translates line-by-line; empty lines pass through. Calls back on the
    /// main thread. `skipIf` is asked just before the job runs — a result
    /// nobody wants any more (the track changed while it waited) never costs
    /// a model run.
    func translate(lines: [String], from source: String, to target: String,
                   skipIf: @escaping () -> Bool = { false },
                   completion: @escaping (TranslateOutcome) -> Void) {
        enqueue(Job(source: source, target: target,
                    work: .translate(lines: lines, skipIf: skipIf, completion: completion)))
    }

    /// Shows the host window and lets macOS ask for the pack download; true
    /// when the pack is installed afterwards. Only ever started from Settings.
    func downloadLanguagePack(from source: String, to target: String,
                              completion: @escaping (Bool) -> Void) {
        enqueue(Job(source: source, target: target, work: .download(completion)))
    }

    /// The pair's pack state. The framework's own status enum is mapped here
    /// and never leaves this file.
    func availability(from source: String, to target: String) async -> PackStatus {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        switch status {
        case .installed: return .installed
        case .supported: return .downloadable  // the pack exists, not downloaded
        default: return .unsupported
        }
    }

    /// Catalog ids macOS can translate between (as source or target).
    func supportedLanguageIDs() async -> Set<String> {
        let languages = await LanguageAvailability().supportedLanguages
        // maximalIdentifier spells the script out ("zh-Hans-CN"), which is
        // what tells the two Chinese entries apart.
        return Set(languages.compactMap { TranslationCatalog.normalize($0.maximalIdentifier) })
    }

    // MARK: - Queue

    private func enqueue(_ job: Job) {
        queue.append(job)
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = job
        Task { @MainActor in
            switch job.work {
            case .translate(let lines, let skipIf, _):
                // Asked first: the model must not run for a result nobody wants.
                if skipIf() {
                    self.complete(job, .translate(.skipped))
                    return
                }
                switch await self.availability(from: job.source, to: job.target) {
                case .downloadable:
                    // A song change must never pop the consent sheet —
                    // downloads are started from Settings.
                    self.complete(job, .translate(.packNotDownloaded))
                case .unsupported:
                    self.complete(job, .translate(.unsupported))
                case .installed:
                    self.parkInvisible()
                    self.run(job, lines: lines) { [weak self] result in
                        self?.complete(job, .translate(result.map(TranslateOutcome.translated) ?? .failed))
                    }
                    // `weak job` on purpose: a finished job must be free to
                    // deallocate (it holds the caller's lines and closures);
                    // a live one is retained by `current`.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.translateTimeout) { [weak self, weak job] in
                        guard let self, let job, self.current === job else { return }
                        warn("translation timed out: \(job.source) → \(job.target)")
                        self.complete(job, .translate(.failed))
                    }
                }
            case .download:
                let status = await self.availability(from: job.source, to: job.target)
                guard status == .downloadable else {  // already installed, or unsupported
                    self.complete(job, .download(installed: status == .installed))
                    return
                }
                self.showForConsent()
                self.run(job, lines: []) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        let now = await self.availability(from: job.source, to: job.target)
                        self.complete(job, .download(installed: now == .installed))
                    }
                }
            }
        }
    }

    /// Ends `job` exactly once (anything but the in-flight job is a late or
    /// duplicate answer), hands its result to the caller, and starts the next.
    private func complete(_ job: Job, _ result: JobResult) {
        guard current === job else { return }
        current = nil
        window.orderOut(nil)
        model.job = nil  // a task that hasn't picked this job up yet finds nothing
        switch (job.work, result) {
        case (.translate(_, _, let completion), .translate(let outcome)): completion(outcome)
        case (.download(let completion), .download(let installed)): completion(installed)
        default: break  // kinds never cross: each branch above builds its own result
        }
        startNextIfIdle()
    }

    /// Hands the job to the host view's task: a new configuration fires it,
    /// an unchanged pair needs invalidate() to re-fire.
    private func run(_ job: Job, lines: [String], completion: @escaping ([String]?) -> Void) {
        let source = Locale.Language(identifier: job.source)
        let target = Locale.Language(identifier: job.target)
        model.message = "Preparing \(TranslationCatalog.name(for: job.source)) → "
            + "\(TranslationCatalog.name(for: job.target)) translation…"
        model.job = (lines, completion)
        if model.configuration?.source == source, model.configuration?.target == target {
            model.configuration?.invalidate()
        } else {
            model.configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// Front and visible: macOS presents the pack-download consent sheet on it.
    private func showForConsent() {
        window.alphaValue = 1
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// The task only runs while the view is in a displayed window, so park it
    /// on-screen but effectively invisible.
    private func parkInvisible() {
        window.alphaValue = 0.01
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 2,
                                          y: screen.visibleFrame.minY + 2))
        }
        window.orderFrontRegardless()
    }
}

/// Debug entry (`--translate-check file.lrc`): plan batches with every catalog
/// language enabled (target English), translate each, print.
@available(macOS 15.0, *)
enum TranslateCheck {
    // Keeps the translator (and its host window) alive for the app's lifetime.
    private static var retained: LyricsTranslator?

    static func run(lrcPath: String) -> Never {
        guard let text = try? String(contentsOfFile: lrcPath, encoding: .utf8) else {
            warn("cannot read \(lrcPath)")
            exit(1)
        }
        let lines = LrcParser.parse(text)
        let texts = lines.map(\.text)
        let target = "en"
        let batches = LanguageGate.plan(
            lines: texts, enabledSources: Set(TranslationCatalog.languages.map(\.id)),
            target: target, recognizer: AppleLanguageRecognizer.recognize)
        warn("lines: \(lines.count), batches: \(batches.count)")
        let planned = Set(batches.flatMap(\.indices))
        for (index, line) in lines.enumerated() where !planned.contains(index) {
            print("[\(line.ms)ms] left alone: \(line.text)")
        }
        guard !batches.isEmpty else {
            print("nothing to translate — would be shown as-is")
            exit(0)
        }
        let translator = LyricsTranslator()
        retained = translator
        var remaining = batches.count
        DispatchQueue.main.async {
            for batch in batches {
                print("batch \(batch.source) → \(target): lines \(batch.indices)")
                translator.translate(lines: batch.indices.map { texts[$0] },
                                     from: batch.source, to: target) { outcome in
                    switch outcome {
                    case .translated(let translated):
                        for (j, index) in batch.indices.enumerated() where j < translated.count {
                            let accepted = LanguageGate.isPlausibleOutput(translated[j], target: target)
                            print("[\(lines[index].ms)ms] \(batch.source): \(texts[index]) → "
                                  + translated[j] + (accepted ? "" : "  (rejected: not \(target))"))
                        }
                    case .packNotDownloaded:
                        print("batch \(batch.source) → \(target): pack not downloaded")
                    case .unsupported:
                        print("batch \(batch.source) → \(target): pair unsupported")
                    case .failed:
                        print("batch \(batch.source) → \(target): translation failed")
                    case .skipped:
                        print("batch \(batch.source) → \(target): skipped")
                    }
                    remaining -= 1
                    if remaining == 0 {
                        exit(0)
                    }
                }
            }
        }
        NSApplication.shared.run()
        fatalError("unreachable")
    }
}
