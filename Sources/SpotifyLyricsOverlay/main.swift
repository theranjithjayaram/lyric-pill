import AppKit

// Single-instance guard: the LaunchAgent and a manual `open` must not stack.
if let bundleId = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty {
        exit(0)
    }
}

if let flag = CommandLine.arguments.firstIndex(of: "--translate-check"),
   flag + 1 < CommandLine.arguments.count {
    if #available(macOS 15.0, *) {
        TranslateCheck.run(lrcPath: CommandLine.arguments[flag + 1])
    }
    FileHandle.standardError.write(Data("--translate-check requires macOS 15+\n".utf8))
    exit(1)
}

var simulatePath: String?
if let flag = CommandLine.arguments.firstIndex(of: "--simulate"),
   flag + 1 < CommandLine.arguments.count {
    simulatePath = CommandLine.arguments[flag + 1]
}

let app = NSApplication.shared
// .accessory keeps us out of the Dock even when run unbundled (`swift run`);
// the bundled app also sets LSUIElement.
app.setActivationPolicy(.accessory)

let controller = AppController(simulateLrcPath: simulatePath)
controller.start()
app.run()
