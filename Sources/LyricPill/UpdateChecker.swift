import AppKit
import LyricsCore

/// Version strings from the bundle ("dev" when run unbundled via `swift run`).
enum AppInfo {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    static let repoURL = URL(string: "https://github.com/theranjithjayaram/lyric-pill")!
    /// The one identity the app sends over HTTP, in the form lrclib asks for.
    static let userAgent = "lyric-pill/\(version) (\(repoURL.absoluteString))"
}

/// On-demand check against the repo's latest GitHub release. Never automatic:
/// the app makes no network request the user didn't just ask for.
enum UpdateChecker {
    enum Outcome {
        case upToDate(String)
        case available(version: String, url: URL)
        case noReleases
    }

    enum CheckError: LocalizedError {
        case httpStatus(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code): "GitHub answered HTTP \(code)."
            case .malformed: "GitHub's answer couldn't be read."
            }
        }
    }

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/theranjithjayaram/lyric-pill/releases/latest")!

    /// Completion runs on the main thread.
    static func check(currentVersion: String, completion: @escaping (Result<Outcome, Error>) -> Void) {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
        // Ephemeral: no cookie jar, no CFNetwork disk cache for a one-off GET.
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request) { data, response, error in
            let result: Result<Outcome, Error>
            if let error {
                result = .failure(error)
            } else {
                result = Result { try outcome(currentVersion: currentVersion, data: data ?? Data(),
                                               status: (response as? HTTPURLResponse)?.statusCode ?? 0) }
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        session.finishTasksAndInvalidate()
    }

    private static func outcome(currentVersion: String, data: Data, status: Int) throws -> Outcome {
        if status == 404 { return .noReleases }  // repo exists, nothing published yet
        guard status == 200 else { throw CheckError.httpStatus(status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw CheckError.malformed
        }
        guard let latest = SemanticVersion(tag) else { throw CheckError.malformed }  // tags are "v1.2.3"
        // An unparseable current version ("dev") is never "up to date".
        if let current = SemanticVersion(currentVersion), latest <= current {
            return .upToDate(currentVersion)
        }
        return .available(version: latest.description, url: page)
    }

    /// Shows the result as an alert; "Download" opens the release page.
    static func present(_ result: Result<Outcome, Error>, currentVersion: String) {
        let alert = NSAlert()
        var downloadURL: URL?
        switch result {
        case .success(.upToDate(let version)):
            alert.messageText = "LyricPill \(version) is up to date."
            alert.addButton(withTitle: "OK")
        case .success(.available(let version, let url)):
            alert.messageText = "LyricPill \(version) is available (you have \(currentVersion))."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            downloadURL = url
        case .success(.noReleases):
            alert.messageText = "No releases have been published yet."
            alert.addButton(withTitle: "OK")
        case .failure(let error):
            alert.messageText = "Couldn't check for updates."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
        }
        if alert.runModal() == .alertFirstButtonReturn, let downloadURL {
            NSWorkspace.shared.open(downloadURL)
        }
    }
}
