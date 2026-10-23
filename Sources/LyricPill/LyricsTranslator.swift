import AppKit
import LyricsCore
import SwiftUI
import Translation

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
        case translate([String], ([String]?) -> Void)
        case download((Bool) -> Void)
    }

    private struct Job {
        let source: String  // catalog ids
        let target: String
        let work: Work
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
                        FileHandle.standardError.write(Data("translation failed: \(error)\n".utf8))
                        await MainActor.run { completion(nil) }
                    }
                }
        }
    }

    private let model = Model()
    private let window: NSWindow
    // FIFO: one job in flight, the next starts when it completes — songs can
    // change faster than a translation finishes, and dropping the second
    // request would silently skip that song.
    private var queue: [Job] = []
    private var busy = false
    // Identifies the in-flight job, so a late or duplicate answer (a task
    // SwiftUI cancelled, or one that fires after the deadline) is ignored.
    private var jobGen = 0
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
    /// main thread with nil when translation isn't possible (pair unsupported,
    /// pack not downloaded, framework error) — caller keeps the original.
    func translate(lines: [String], from source: String, to target: String,
                   completion: @escaping ([String]?) -> Void) {
        enqueue(Job(source: source, target: target, work: .translate(lines, completion)))
    }

    /// Shows the host window and lets macOS ask for the pack download; true
    /// when the pack is installed afterwards. Only ever started from Settings.
    func downloadLanguagePack(from source: String, to target: String,
                              completion: @escaping (Bool) -> Void) {
        enqueue(Job(source: source, target: target, work: .download(completion)))
    }

    func availability(from source: String, to target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
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
        guard !busy, let job = queue.first else { return }
        busy = true
        jobGen += 1
        let gen = jobGen
        Task { @MainActor in
            let status = await self.availability(from: job.source, to: job.target)
            switch job.work {
            case .translate(let lines, _):
                // .supported = pack not downloaded. A song change must never
                // pop the consent sheet — downloads are started from Settings.
                guard status == .installed else {
                    self.complete(gen, lines: nil)
                    return
                }
                self.show(interactive: false)
                self.run(job, lines: lines) { [weak self] result in
                    self?.complete(gen, lines: result)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.translateTimeout) { [weak self] in
                    guard let self, self.busy, gen == self.jobGen else { return }
                    FileHandle.standardError.write(
                        Data("translation timed out: \(job.source) → \(job.target)\n".utf8))
                    self.complete(gen, lines: nil)
                }
            case .download:
                guard status == .supported else {  // already installed, or unsupported
                    self.complete(gen, installed: status == .installed)
                    return
                }
                self.show(interactive: true)
                self.run(job, lines: []) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        let now = await self.availability(from: job.source, to: job.target)
                        self.complete(gen, installed: now == .installed)
                    }
                }
            }
        }
    }

    /// Ends the in-flight job exactly once (a stale gen is a late or duplicate
    /// answer), hands its result to the caller, and starts the next.
    private func complete(_ gen: Int, lines: [String]? = nil, installed: Bool = false) {
        guard busy, gen == jobGen, let job = queue.first else { return }
        window.orderOut(nil)
        model.job = nil  // a task that hasn't picked this job up yet finds nothing
        queue.removeFirst()
        busy = false
        switch job.work {
        case .translate(_, let completion): completion(lines)
        case .download(let completion): completion(installed)
        }
        startNextIfIdle()
    }

    /// Hands the job to the host view's task: a new configuration fires it,
    /// an unchanged pair needs invalidate() to re-fire.
    private func run(_ job: Job, lines: [String], completion: @escaping ([String]?) -> Void) {
        let source = Locale.Language(identifier: job.source)
        let target = Locale.Language(identifier: job.target)
        model.message = "Preparing \(Self.name(job.source)) → \(Self.name(job.target)) translation…"
        model.job = (lines, completion)
        if model.configuration?.source == source, model.configuration?.target == target {
            model.configuration?.invalidate()
        } else {
            model.configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private static func name(_ id: String) -> String {
        TranslationCatalog.language(for: id)?.name ?? id
    }

    private func show(interactive: Bool) {
        if interactive {
            window.alphaValue = 1
            window.level = .floating
            window.center()
            window.makeKeyAndOrderFront(nil)
        } else {
            // The task only runs while the view is in a displayed window, so
            // park it on-screen but effectively invisible.
            window.alphaValue = 0.01
            if let screen = NSScreen.main {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 2,
                                              y: screen.visibleFrame.minY + 2))
            }
            window.orderFrontRegardless()
        }
    }
}

/// Debug entry (`--translate-check file.lrc`): plan batches with every catalog
/// language enabled (target English), translate each, print.
@available(macOS 15.0, *)
enum TranslateCheck {
    // Keeps the translator (and its host window) alive for the app's lifetime.
    private static var retained: LyricsTranslator?

    static func run(lrcPath: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let text = try? String(contentsOfFile: lrcPath, encoding: .utf8) else {
            FileHandle.standardError.write(Data("cannot read \(lrcPath)\n".utf8))
            exit(1)
        }
        let lines = LrcParser.parse(text)
        let texts = lines.map(\.text)
        let target = "en"
        let batches = LanguageGate.plan(
            lines: texts, enabledSources: Set(TranslationCatalog.languages.map(\.id)),
            target: target, recognizer: AppleLanguageRecognizer.recognize)
        FileHandle.standardError.write(
            Data("lines: \(lines.count), batches: \(batches.count)\n".utf8))
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
                                     from: batch.source, to: target) { translated in
                    if let translated {
                        for (j, index) in batch.indices.enumerated() where j < translated.count {
                            let accepted = LanguageGate.isPlausibleOutput(translated[j], target: target)
                            print("[\(lines[index].ms)ms] \(batch.source): \(texts[index]) → "
                                  + translated[j] + (accepted ? "" : "  (rejected: not \(target))"))
                        }
                    } else {
                        print("batch \(batch.source) → \(target): unavailable (pack not installed or pair unsupported)")
                    }
                    remaining -= 1
                    if remaining == 0 {
                        exit(0)
                    }
                }
            }
        }
        app.run()
        fatalError("unreachable")
    }
}
