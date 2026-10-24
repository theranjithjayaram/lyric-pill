import AppKit

/// Reports whether macOS lets us send Apple events to Spotify (the TCC
/// "Automation" grant), without prompting and without launching Spotify.
enum SpotifyAutomation {
    enum Status: Equatable {
        case allowed, denied, notDetermined, spotifyNotRunning
        case other(OSStatus)

        var description: String {
            switch self {
            case .allowed: "Allowed"
            case .denied: "Denied — lyrics can't follow Spotify"
            case .notDetermined: "Not asked yet — macOS prompts on first playback"
            case .spotifyNotRunning: "Spotify is not running (can't check)"
            case .other(let code): "Unknown (error \(code))"
            }
        }
    }

    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Asks tccd on a background queue and answers on the main thread: the
    /// probe is a synchronous round-trip, and the app must never hang on it.
    static func status(completion: @escaping (Status) -> Void) {
        // Target by PID, never by bundle id: on macOS 26 the bundle-id
        // descriptor makes AEDeterminePermissionToAutomateTarget block forever
        // (measured: PID form answers in ~50 ms, bundle-id form never returns).
        // A non-running Spotify is answered here, so nothing can launch it.
        guard let spotify = SpotifyWatcher.runningSpotify else {
            completion(.spotifyNotRunning)
            return
        }
        let target = NSAppleEventDescriptor(processIdentifier: spotify.processIdentifier)
        DispatchQueue.global(qos: .userInitiated).async {
            // `target` is captured so its aeDesc pointer stays valid in here.
            let err = AEDeterminePermissionToAutomateTarget(
                target.aeDesc!, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
            let status: Status
            switch Int(err) {
            case 0: status = .allowed                 // noErr
            case -1743: status = .denied              // errAEEventNotPermitted
            case -1744: status = .notDetermined       // errAEEventWouldRequireUserConsent
            case -600: status = .spotifyNotRunning    // procNotFound
            default: status = .other(err)
            }
            DispatchQueue.main.async { completion(status) }
        }
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
