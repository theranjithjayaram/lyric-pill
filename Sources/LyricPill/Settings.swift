import Combine
import Foundation

enum OverlayMode: String, CaseIterable {
    case off, on, auto

    var title: String {
        switch self {
        case .off: "Off"
        case .on: "On"
        case .auto: "Auto"
        }
    }
}

/// UserDefaults-backed settings. Observable so the Settings window and the
/// controller both follow one source of truth: every property persists on
/// write and is read back from defaults at launch.
// Main-thread-only by convention, like the rest of the app (no @MainActor).
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    static let fontSizeRange: ClosedRange<Double> = 14...36
    static let opacityRange: ClosedRange<Double> = 0.2...1.0

    @Published var mode: OverlayMode {
        didSet { defaults.set(mode.rawValue, forKey: "mode") }
    }
    /// Translate lyrics on-device (macOS 15+).
    @Published var translateEnabled: Bool {
        didSet { defaults.set(translateEnabled, forKey: "translate-enabled") }
    }
    /// Catalog ids of the languages lyrics may be translated *from*.
    @Published var translateSources: [String] {
        didSet { defaults.set(translateSources, forKey: "translate-sources") }
    }
    /// Catalog id of the language lyrics are translated *into*.
    @Published var translateTarget: String {
        didSet { defaults.set(translateTarget, forKey: "translate-target") }
    }
    @Published var pillFontSize: Double {
        didSet { defaults.set(pillFontSize, forKey: "pill-font-size") }
    }
    @Published var pillOpacity: Double {
        didSet { defaults.set(pillOpacity, forKey: "pill-opacity") }
    }
    @Published var firstRunDone: Bool {
        didSet { defaults.set(firstRunDone, forKey: "first-run-done") }
    }

    private let defaults = UserDefaults.standard

    private init() {
        // One-time migration from the single-pair era: the old toggle becomes
        // the general on/off switch; the pair itself moves to sources/target.
        if defaults.object(forKey: "translate-enabled") == nil,
           let legacy = defaults.object(forKey: "translate-hindi") as? Bool {
            defaults.set(legacy, forKey: "translate-enabled")
        }

        mode = OverlayMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .auto
        translateEnabled = defaults.object(forKey: "translate-enabled") as? Bool ?? true
        translateSources = defaults.stringArray(forKey: "translate-sources") ?? ["hi"]
        translateTarget = defaults.string(forKey: "translate-target") ?? "en"
        // Clamped on read so a hand-edited defaults value can't produce an
        // unreadable pill; the sliders keep writes in range.
        pillFontSize = Self.fontSizeRange.clamp(defaults.object(forKey: "pill-font-size") as? Double ?? 20)
        pillOpacity = Self.opacityRange.clamp(defaults.object(forKey: "pill-opacity") as? Double ?? 0.55)
        firstRunDone = defaults.bool(forKey: "first-run-done")
    }

    /// Center of the overlay pill in screen coordinates; nil until first
    /// dragged. Written on every drag step, so not published — nothing
    /// observes it.
    var savedCenter: CGPoint? {
        get {
            guard defaults.object(forKey: "center-x") != nil,
                  defaults.object(forKey: "center-y") != nil else { return nil }
            return CGPoint(x: defaults.double(forKey: "center-x"),
                           y: defaults.double(forKey: "center-y"))
        }
        set {
            if let point = newValue {
                defaults.set(Double(point.x), forKey: "center-x")
                defaults.set(Double(point.y), forKey: "center-y")
            } else {
                defaults.removeObject(forKey: "center-x")
                defaults.removeObject(forKey: "center-y")
            }
        }
    }
}

private extension ClosedRange where Bound == Double {
    func clamp(_ value: Double) -> Double {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
