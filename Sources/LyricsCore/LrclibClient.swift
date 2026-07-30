import CryptoKit
import Foundation

/// Fetches time-synced lyrics from lrclib.net with a disk cache.
///
/// Definitive misses (track not on lrclib / no synced lyrics) are cached so a
/// track is only ever asked about once. Transport failures are NOT cached —
/// unlike the Ubuntu reference — so a song first played offline gets another
/// chance next time.
public final class LrclibClient {
    public typealias HttpGet = (URL) throws -> (status: Int, body: String)

    private static let base = "https://lrclib.net"
    private static let userAgent = "spotify-lyrics-overlay-mac/0.1 (https://lrclib.net)"

    private let cacheDir: URL
    private let httpGet: HttpGet

    private enum FetchResult {
        case found(String)  // synced lyrics
        case miss           // definitive "no lyrics" — cacheable
        case abort          // transport/parse failure — not cacheable
    }

    public init(cacheDir: URL, httpGet: @escaping HttpGet = LrclibClient.defaultHttpGet) {
        self.cacheDir = cacheDir
        self.httpGet = httpGet
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Return an LRC string or nil. Blocking — call from a background queue.
    public func getSynced(artist: String, title: String, album: String, durationS: Int) -> String? {
        let key = [artist, title, album, String(durationS)].joined(separator: "|")
        let path = cachePath(for: key)
        if let cached = try? String(contentsOf: path, encoding: .utf8) {
            return cached.isEmpty ? nil : cached  // empty file = cached miss
        }

        switch fetch(artist: artist, title: title, album: album, durationS: durationS) {
        case .found(let lrc):
            // .atomic = temp file + rename, so a concurrent reader never sees a torn file.
            try? Data(lrc.utf8).write(to: path, options: .atomic)
            return lrc
        case .miss:
            try? Data().write(to: path, options: .atomic)
            return nil
        case .abort:
            return nil
        }
    }

    private func cachePath(for key: String) -> URL {
        let hex = Insecure.SHA1.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(hex + ".lrc")
    }

    private func fetch(artist: String, title: String, album: String, durationS: Int) -> FetchResult {
        switch fetchGet(artist: artist, title: title, album: album, durationS: durationS) {
        case .found(let lrc): return .found(lrc)
        case .abort: return .abort
        case .miss: return fetchSearch(artist: artist, title: title, durationS: durationS)
        }
    }

    /// Exact lookup: GET /api/get?artist_name=&track_name=&album_name=&duration=
    private func fetchGet(artist: String, title: String, album: String, durationS: Int) -> FetchResult {
        var comps = URLComponents(string: Self.base + "/api/get")!
        comps.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(durationS)),
        ]
        do {
            let (status, body) = try httpGet(comps.url!)
            guard status == 200, !body.isEmpty else { return .miss }
            guard let obj = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            else { return .abort }
            if let lrc = obj["syncedLyrics"] as? String, !lrc.isEmpty { return .found(lrc) }
            return .miss
        } catch {
            return .abort
        }
    }

    /// Fallback: GET /api/search and pick the closest duration match.
    private func fetchSearch(artist: String, title: String, durationS: Int) -> FetchResult {
        var comps = URLComponents(string: Self.base + "/api/search")!
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        do {
            let (status, body) = try httpGet(comps.url!)
            guard status == 200, !body.isEmpty else { return .miss }
            guard let items = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]]
            else { return .abort }
            let candidates = items.compactMap { item -> (lrc: String, duration: Int)? in
                guard let lrc = item["syncedLyrics"] as? String, !lrc.isEmpty else { return nil }
                return (lrc, (item["duration"] as? NSNumber)?.intValue ?? 0)
            }
            guard let best = candidates.min(by: {
                abs($0.duration - durationS) < abs($1.duration - durationS)
            }) else { return .miss }
            return .found(best.lrc)
        } catch {
            return .abort
        }
    }

    /// Synchronous URLSession wrapper — only ever called on a background queue.
    public static func defaultHttpGet(_ url: URL) throws -> (status: Int, body: String) {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(status: Int, body: String), Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                result = .success((http.statusCode, body))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }
}
