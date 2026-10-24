import AppKit
import LyricsCore
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable {
    case general, translation, about
}

/// One source→target pair's language-pack state, free of Translation-framework
/// types so the view compiles for macOS 13.
enum PackStatus {
    case installed, downloadable, unsupported
}

/// What the Settings view needs from the controller, as closures: the view
/// stays plain SwiftUI and the translator stays type-erased behind the
/// macOS 15 availability check.
struct SettingsServices {
    struct Translation {
        var supportedLanguageIDs: () async -> Set<String>
        var packStatus: (_ source: String, _ target: String) async -> PackStatus
        var downloadPack: (_ source: String, _ target: String, _ completion: @escaping (Bool) -> Void) -> Void
    }

    var resetPillPosition: () -> Void
    /// nil before macOS 15 — the tab explains instead.
    var translation: Translation?
}

/// Owns the single Settings window; created on first use, kept for the app's
/// lifetime (closing just hides it).
// Main-thread-only by convention, like the rest of the app (no @MainActor).
final class SettingsWindowController {
    private final class TabSelection: ObservableObject {
        @Published var tab: SettingsTab = .general
    }

    private let window: NSWindow
    private let selection = TabSelection()
    private var centered = false

    private static let contentSize = NSSize(width: 520, height: 460)

    init(services: SettingsServices) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "LyricPill Settings"
        window.isReleasedWhenClosed = false
        // The window owns its size: left to the hosting controller it starts
        // at 0×0 (so center() lands wrong) and grows to SwiftUI's idea later.
        let hosting = NSHostingController(
            rootView: SettingsView(store: .shared, selection: selection, services: services))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.contentSize)
    }

    func show(tab: SettingsTab) {
        selection.tab = tab
        // An accessory app has no Dock presence: activate explicitly so the
        // window comes to the front instead of opening behind Spotify.
        NSApp.activate(ignoringOtherApps: true)
        if !centered {
            window.center()
            centered = true
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Debug (`--snapshot-settings`): render the window's content to a PNG —
    /// the way to eyeball layout on a Mac without Screen Recording permission.
    func snapshot(to path: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    private struct SettingsView: View {
        @ObservedObject var store: SettingsStore
        @ObservedObject var selection: TabSelection
        let services: SettingsServices

        var body: some View {
            TabView(selection: $selection.tab) {
                GeneralTab(store: store, services: services)
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(SettingsTab.general)
                TranslationTab(store: store, services: services.translation)
                    .tabItem { Label("Translation", systemImage: "character.bubble") }
                    .tag(SettingsTab.translation)
                AboutTab()
                    .tabItem { Label("About", systemImage: "info.circle") }
                    .tag(SettingsTab.about)
            }
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    let services: SettingsServices

    @State private var loginStatus: SMAppService.Status = .notRegistered
    @State private var loginError: String?
    @State private var automation: SpotifyAutomation.Status = .spotifyNotRunning

    var body: some View {
        Form {
            Section {
                Picker("Lyrics overlay", selection: $store.mode) {
                    ForEach(OverlayMode.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)

                Toggle("Launch at login", isOn: launchAtLogin)
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve in System Settings → Login Items")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { LoginItem.openSystemSettings() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Spotify access") {
                HStack {
                    Text(automation.description)
                    Spacer()
                    // Re-read on demand, never on a timer.
                    Button("Refresh") { SpotifyAutomation.status { automation = $0 } }
                }
                Button("Open Automation Settings…") { SpotifyAutomation.openSystemSettings() }
            }

            Section("Pill") {
                HStack {
                    Slider(value: $store.pillFontSize, in: SettingsStore.fontSizeRange, step: 1) {
                        Text("Font size")
                    }
                    Text("\(Int(store.pillFontSize)) pt")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Slider(value: $store.pillOpacity, in: SettingsStore.opacityRange) {
                        Text("Opacity")
                    }
                    Text("\(Int((store.pillOpacity * 100).rounded()))%")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Button("Reset Position") { services.resetPillPosition() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loginStatus = LoginItem.status
            SpotifyAutomation.status { automation = $0 }
        }
    }

    /// `.requiresApproval` reads as on: the registration exists, macOS just
    /// hasn't let it run yet.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: { on in
                do {
                    try LoginItem.setEnabled(on)
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                }
                loginStatus = LoginItem.status
            })
    }
}

// MARK: - Translation

private struct TranslationTab: View {
    @ObservedObject var store: SettingsStore
    let services: SettingsServices.Translation?

    @State private var supported: Set<String> = []
    @State private var statuses: [String: PackStatus] = [:]
    @State private var downloading: Set<String> = []

    // Wide enough for the "Downloading…" button, so the switch column never moves.
    private static let statusColumnWidth: CGFloat = 124

    var body: some View {
        if let services {
            form(services)
        } else {
            Text("On-device translation requires macOS 15 or later.")
                .foregroundStyle(.secondary)
        }
    }

    private func form(_ services: SettingsServices.Translation) -> some View {
        Form {
            Section {
                Toggle("Translate lyrics", isOn: $store.translateEnabled)
                Picker("Translate into", selection: $store.translateTarget) {
                    ForEach(targets, id: \.id) { Text($0.name).tag($0.id) }
                }
            }

            Section("Translate from") {
                ForEach(sources, id: \.id) { language in
                    // Name, then two fixed trailing columns (switch, pack
                    // status): a labelled Toggle next to a Spacer let each
                    // row place its switch wherever its label and status
                    // widths happened to leave it.
                    HStack {
                        Text(language.name)
                        Spacer()
                        Toggle(language.name, isOn: sourceEnabled(language.id))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(statuses[language.id] == .unsupported)
                        packView(language.id, services)
                            .frame(width: Self.statusColumnWidth, alignment: .trailing)
                    }
                }
            }

            Section {
                Text("Language packs are downloaded and stored by macOS and run entirely on this Mac. Manage them in System Settings → General → Language & Region → Translation Languages.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Open System Settings…") { openLanguageSettings() }
            }
        }
        .formStyle(.grouped)
        // Pack statuses depend on the target: reload on appear and whenever it changes.
        .task(id: store.translateTarget) { await reload(services) }
    }

    /// Catalog languages macOS can translate into. The current target is
    /// always listed so the picker never shows an empty selection while the
    /// supported set is still loading.
    private var targets: [TranslationLanguage] {
        TranslationCatalog.languages.filter {
            supported.contains($0.id) || $0.id == store.translateTarget
        }
    }

    private var sources: [TranslationLanguage] {
        TranslationCatalog.languages.filter { $0.id != store.translateTarget }
    }

    private func sourceEnabled(_ id: String) -> Binding<Bool> {
        Binding(
            get: { store.translateSources.contains(id) },
            set: { on in
                var ids = store.translateSources.filter { $0 != id }
                if on { ids.append(id) }
                store.translateSources = ids
            })
    }

    @ViewBuilder
    private func packView(_ id: String, _ services: SettingsServices.Translation) -> some View {
        switch statuses[id] {
        case .installed:
            Text("Installed ✓").foregroundStyle(.secondary)
        case .downloadable:
            Button(downloading.contains(id) ? "Downloading…" : "Download…") {
                downloading.insert(id)
                services.downloadPack(id, store.translateTarget) { _ in
                    downloading.remove(id)
                    Task { await reload(services) }
                }
            }
            .disabled(downloading.contains(id))
        case .unsupported:
            Text("Unavailable").foregroundStyle(.secondary)
        case nil:
            Text("…").foregroundStyle(.secondary)
        }
    }

    private func reload(_ services: SettingsServices.Translation) async {
        supported = await services.supportedLanguageIDs()
        let target = store.translateTarget
        var fresh: [String: PackStatus] = [:]
        for language in TranslationCatalog.languages where language.id != target {
            fresh[language.id] = await services.packStatus(language.id, target)
        }
        statuses = fresh
    }

    private func openLanguageSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 96, height: 96)
                    Text("LyricPill").font(.title2).bold()
                    Text("Version \(AppInfo.version) (build \(AppInfo.build))")
                        .foregroundStyle(.secondary)
                    Text("The current Spotify lyric line as a floating pill, translated on-device.")
                        .multilineTextAlignment(.center)
                    Button(checking ? "Checking…" : "Check for Updates…") { checkForUpdates() }
                        .disabled(checking)
                        .padding(.top, 4)
                    HStack {
                        Button("GitHub") { open(AppInfo.repoURL) }
                        Button("Report an Issue") { open(AppInfo.repoURL.appendingPathComponent("issues")) }
                        Button("Privacy") { open(AppInfo.repoURL.appendingPathComponent("blob/main/PRIVACY.md")) }
                        Button("License (MIT)") { open(AppInfo.repoURL.appendingPathComponent("blob/main/LICENSE")) }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                Text("Lyrics are fetched at runtime from lrclib.net. Not affiliated with Spotify.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func checkForUpdates() {
        checking = true
        UpdateChecker.check(currentVersion: AppInfo.version) { result in
            checking = false
            UpdateChecker.present(result, currentVersion: AppInfo.version)
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
