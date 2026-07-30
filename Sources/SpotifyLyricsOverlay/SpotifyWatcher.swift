import AppKit

/// Watches Spotify without polling while idle: its distributed
/// "PlaybackStateChanged" notification wakes us on play/pause/track/seek, and
/// authoritative state is then read over Apple events (one small round-trip).
final class SpotifyWatcher {
    struct Snapshot: Equatable {
        var playing: Bool
        var positionMs: Int
        var trackId: String
        var title: String
        var artist: String
        var album: String
        var durationMs: Int
    }

    var onSnapshot: ((Snapshot) -> Void)?
    var onPlayerGone: (() -> Void)?
    /// Last Apple-events failure (e.g. Automation permission denied), for the menu.
    private(set) var lastError: String?

    private static let spotifyBundleId = "com.spotify.client"
    private static let playbackChangedName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    // Compiled once and reused. Numbers are returned as raw descriptors (not
    // text) so locale decimal separators can never corrupt the position.
    // `player position` is seconds (real); `duration` is milliseconds (int) —
    // that mismatch is a Spotify AppleScript quirk, normalized in refresh().
    // NB: `st` is not a usable variable name — AppleScript reserves it as the
    // ordinal suffix (1st), and the compile error surfaces only at runtime.
    private let script = NSAppleScript(source: """
        tell application "Spotify"
            set stateFlag to 0
            set pos to 0
            try
                if player state is playing then set stateFlag to 1
                set pos to player position
                set t to current track
                return {stateFlag, pos, id of t, name of t, artist of t, album of t, duration of t}
            on error
                return {stateFlag, pos, "", "", "", "", 0}
            end try
        end tell
        """)!

    var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.spotifyBundleId).isEmpty
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playbackChanged(_:)),
            name: Self.playbackChangedName, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func playbackChanged(_ note: Notification) {
        refresh()
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Self.spotifyBundleId {
            onPlayerGone?()
        }
    }

    /// Read the live player state. Main thread only (NSAppleScript requirement).
    func refresh() {
        // Never send Apple events to a non-running Spotify — that would launch it.
        guard isSpotifyRunning else {
            onPlayerGone?()
            return
        }
        var errorInfo: NSDictionary?
        let desc = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            lastError = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "Apple events to Spotify failed"
            return
        }
        lastError = nil
        guard desc.numberOfItems == 7 else { return }
        let positionSeconds = desc.atIndex(2)?.doubleValue ?? 0
        onSnapshot?(Snapshot(
            playing: desc.atIndex(1)?.int32Value == 1,
            positionMs: Int(positionSeconds * 1000),
            trackId: desc.atIndex(3)?.stringValue ?? "",
            title: desc.atIndex(4)?.stringValue ?? "",
            artist: desc.atIndex(5)?.stringValue ?? "",
            album: desc.atIndex(6)?.stringValue ?? "",
            durationMs: Int(desc.atIndex(7)?.int32Value ?? 0)))
    }
}
