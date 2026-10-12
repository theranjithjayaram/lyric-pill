import AppKit
import LyricsCore
import SwiftUI
import Translation

/// On-device Hindi → English translation of lyric lines via Apple's
/// Translation framework (macOS 15+). The framework only hands out sessions
/// through a SwiftUI `.translationTask`, so a tiny host window carries one:
/// invisible for normal work, shown briefly only when macOS needs the user's
/// one-time consent to download the language model.
// Main-thread-only by convention, like the rest of the app (no @MainActor:
// the annotation would make every nonisolated caller a hard error).
@available(macOS 15.0, *)
final class LyricsTranslator {
    private static let source = Locale.Language(identifier: "hi")
    private static let target = Locale.Language(identifier: "en")

    private final class Model: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
        var job: (lines: [String], completion: ([String]?) -> Void)?
    }

    private struct HostView: View {
        @ObservedObject var model: Model

        var body: some View {
            Text("Preparing Hindi → English translation…")
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
                        let responses = try await session.translations(from: requests)
                        var out = lines
                        for response in responses {
                            if let id = response.clientIdentifier, let i = Int(id), i < out.count {
                                out[i] = response.targetText
                            }
                        }
                        let result = out
                        await MainActor.run { completion(result) }
                    } catch {
                        await MainActor.run { completion(nil) }
                    }
                }
        }
    }

    private let model = Model()
    private let window: NSWindow

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
    /// main thread with nil when translation isn't possible (unsupported,
    /// model download declined, framework error) — caller keeps the original.
    func translate(lines: [String], completion: @escaping ([String]?) -> Void) {
        guard model.job == nil else {
            completion(nil)  // one job at a time; songs change rarely
            return
        }
        Task { @MainActor in
            let status = await LanguageAvailability().status(from: Self.source, to: Self.target)
            guard status != .unsupported else {
                completion(nil)
                return
            }
            // .supported = model not yet downloaded — macOS presents its
            // consent sheet on this window, so it must be visible that once.
            self.show(interactive: status == .supported)
            self.model.job = (lines, { [weak self] result in
                self?.window.orderOut(nil)
                completion(result)
            })
            if self.model.configuration == nil {
                self.model.configuration = TranslationSession.Configuration(
                    source: Self.source, target: Self.target)
            } else {
                self.model.configuration?.invalidate()  // re-fires the task
            }
        }
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

/// Debug entry (`--translate-check file.lrc`): detect script, translate, print.
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
        let devanagari = ScriptDetector.isMostlyDevanagari(
            lines.map(\.text).joined(separator: " "))
        FileHandle.standardError.write(
            Data("lines: \(lines.count), devanagari: \(devanagari)\n".utf8))
        guard devanagari else {
            print("not Hindi script — would be shown as-is")
            exit(0)
        }
        let translator = LyricsTranslator()
        retained = translator
        DispatchQueue.main.async {
            translator.translate(lines: lines.map(\.text)) { translated in
                guard let translated else {
                    print("translation unavailable")
                    exit(1)
                }
                for (line, text) in zip(lines, translated) {
                    print("[\(line.ms)ms] \(text)")
                }
                exit(0)
            }
        }
        app.run()
        fatalError("unreachable")
    }
}
