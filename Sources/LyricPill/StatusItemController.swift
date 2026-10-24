import AppKit

/// Menu-bar item: a status line, mode selection (off/on/auto), move mode,
/// translation toggle, Settings/About, quit. Mode and translation write the
/// shared SettingsStore directly; their checkmarks are re-read each time the
/// menu opens so changes made in the Settings window show up too.
final class StatusItemController: NSObject, NSMenuDelegate {
    var onMoveModeChange: ((Bool) -> Void)?
    var onOpenSettings: ((SettingsTab) -> Void)?
    /// Called each time the menu opens — keeps the status line current without
    /// any background refresh.
    var statusText: (() -> String)?

    private let store = SettingsStore.shared
    private let statusItem: NSStatusItem
    private var modeItems: [NSMenuItem] = []
    private let infoItem = NSMenuItem()
    private let moveItem = NSMenuItem()
    private let translateItem = NSMenuItem()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "music.note.list", accessibilityDescription: "LyricPill")

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        infoItem.isEnabled = false
        menu.addItem(infoItem)
        menu.addItem(.separator())

        for mode in OverlayMode.allCases {
            let item = NSMenuItem(
                title: "Mode: \(mode.title)", action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            modeItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        moveItem.title = "Move Mode"
        moveItem.action = #selector(toggleMove(_:))
        moveItem.target = self
        menu.addItem(moveItem)

        if #available(macOS 15.0, *) {
            translateItem.title = "Translate Lyrics"
            translateItem.action = #selector(toggleTranslate(_:))
            translateItem.target = self
            menu.addItem(translateItem)
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(
            title: "About LyricPill", action: #selector(openAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit LyricPill", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
        syncChecks()
    }

    func menuWillOpen(_ menu: NSMenu) {
        infoItem.title = statusText?() ?? ""
        syncChecks()
    }

    private func syncChecks() {
        for item in modeItems {
            item.state = item.representedObject as? String == store.mode.rawValue ? .on : .off
        }
        translateItem.state = store.translateEnabled ? .on : .off
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = OverlayMode(rawValue: raw) else { return }
        store.mode = mode
    }

    @objc private func toggleMove(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        onMoveModeChange?(sender.state == .on)
    }

    @objc private func toggleTranslate(_ sender: NSMenuItem) {
        store.translateEnabled.toggle()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        onOpenSettings?(.general)
    }

    @objc private func openAbout(_ sender: NSMenuItem) {
        onOpenSettings?(.about)
    }
}
