import AppKit

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

/// UserDefaults-backed persistence for the display mode and overlay position.
enum Settings {
    private static let modeKey = "mode"
    private static let centerXKey = "center-x"
    private static let centerYKey = "center-y"

    static var mode: OverlayMode {
        get {
            OverlayMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
        }
    }

    /// Center of the overlay pill in screen coordinates; nil until first dragged.
    static var savedCenter: CGPoint? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: centerXKey) != nil,
                  defaults.object(forKey: centerYKey) != nil else { return nil }
            return CGPoint(x: defaults.double(forKey: centerXKey),
                           y: defaults.double(forKey: centerYKey))
        }
        set {
            let defaults = UserDefaults.standard
            if let point = newValue {
                defaults.set(Double(point.x), forKey: centerXKey)
                defaults.set(Double(point.y), forKey: centerYKey)
            } else {
                defaults.removeObject(forKey: centerXKey)
                defaults.removeObject(forKey: centerYKey)
            }
        }
    }
}
