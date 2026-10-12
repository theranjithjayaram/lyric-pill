import AppKit

/// Menu-bar item: a status line, mode selection (off/on/auto), move mode, quit.
final class StatusItemController: NSObject, NSMenuDelegate {
    var onModeChange: ((OverlayMode) -> Void)?
    var onMoveModeChange: ((Bool) -> Void)?
    var onTranslateChange: ((Bool) -> Void)?
    /// Called each time the menu opens — keeps the status line current without
    /// any background refresh.
    var statusText: (() -> String)?

    private let statusItem: NSStatusItem
    private var modeItems: [NSMenuItem] = []
    private let infoItem = NSMenuItem()
    private let moveItem = NSMenuItem()
    private let translateItem = NSMenuItem()

    init(currentMode: OverlayMode, translateHindi: Bool) {
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
            item.state = mode == currentMode ? .on : .off
            modeItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        moveItem.title = "Move Mode"
        moveItem.action = #selector(toggleMove(_:))
        moveItem.target = self
        menu.addItem(moveItem)

        if #available(macOS 15.0, *) {
            translateItem.title = "Translate Hindi → English"
            translateItem.action = #selector(toggleTranslate(_:))
            translateItem.target = self
            translateItem.state = translateHindi ? .on : .off
            menu.addItem(translateItem)
        }
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit LyricPill", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        infoItem.title = statusText?() ?? ""
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = OverlayMode(rawValue: raw) else { return }
        for item in modeItems {
            item.state = item == sender ? .on : .off
        }
        onModeChange?(mode)
    }

    @objc private func toggleMove(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        onMoveModeChange?(sender.state == .on)
    }

    @objc private func toggleTranslate(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        onTranslateChange?(sender.state == .on)
    }
}
