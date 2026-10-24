import CryptoKit
import Foundation

/// Distinguishes "no lyrics exist" from "couldn't ask": a miss is cached (with
/// a TTL), a failure never is, so the next fetch simply asks again.
public enum LyricsOutcome: Equatable {
    case found(String)  // synced LRC
    case none           // definitive: lrclib has no synced lyrics for this track
    case unavailable    // transport/parse failure — never cached
}

/// Fetches time-synced lyrics from lrclib.net with a disk cache.
///
/// Found lyrics are cached forever. Definitive misses are cached with a TTL —
/// lrclib grows lyrics for fresh releases over time, so a miss must get
/// re-checked eventually. Transport failures are never cached.
public final class LrclibClient {
    public typealias HttpGet = (URL) throws -> (status: Int, body: String)

    private static let base = "https://lrclib.net"
    private static let missTTL: TimeInterval = 24 * 3600
    /// lrclib under load can take several seconds just to accept a connection.
    private static let requestTimeout: TimeInterval = 15
    /// Fallback searches ignore lyrics whose duration strays further than this
    /// from the playing track — the guard against matching a same-named song.
    private static let maxDurationDeltaS = 10

    private let cacheDir: URL
    private let httpGet: HttpGet

    /// `httpGet` is `defaultHttpGet(userAgent:)` in the app; tests inject a fake.
    public init(cacheDir: URL, httpGet: @escaping HttpGet) {
        self.cacheDir = cacheDir
        self.httpGet = httpGet
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Blocking — call from a background queue.
    public func getSynced(artist: String, title: String, album: String, durationS: Int) -> LyricsOutcome {
        let path = cachePath(for: Self.cacheKey(artist: artist, title: title, album: album, durationS: durationS))
        if let cached = try? String(contentsOf: path, encoding: .utf8) {
            if !cached.isEmpty {
                return .found(cached)
            }
            // Empty file = cached miss; honor it only within the TTL.
            let mtime = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
            if let mtime, Date().timeIntervalSince(mtime) < Self.missTTL {
                return .none
            }
        }

        let outcome = fetch(artist: artist, title: title, album: album, durationS: durationS)
        switch outcome {
        case .found(let lrc):
            // .atomic = temp file + rename, so a concurrent reader never sees a torn file.
            try? Data(lrc.utf8).write(to: path, options: .atomic)
        case .none:
            try? Data().write(to: path, options: .atomic)
        case .unavailable:
            break
        }
        return outcome
    }

    // MARK: - Cache layout (shared with lyric-derived caches, e.g. translations)

    /// The identity of a track as lrclib sees it.
    public static func cacheKey(artist: String, title: String, album: String, durationS: Int) -> String {
        [artist, title, album, String(durationS)].joined(separator: "|")
    }

    /// Where `key` lives on disk; derived caches append their own suffix to
    /// a track's key and get a sibling file.
    public func cachePath(for key: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(digest + ".lrc")
    }

    // MARK: - Title cleaning

    private static let annotation = try! NSRegularExpression(
        pattern: #"(?i)\b(from|feat\.?|ft\.?|with|remaster(?:ed)?)\b"#)
    private static let trailingGroup = try! NSRegularExpression(pattern: #"\s*[(\[]([^()\[\]]*)[)\]]\s*$"#)
    private static let dashSuffix = try! NSRegularExpression(pattern: #"(?i)\s+-\s+from\b.*$"#)

    /// Strip trailing annotation suffixes — `(From "Movie")`, `[feat. X]`,
    /// `... - From "Movie"` — that Spotify includes but lrclib usually doesn't.
    /// Content-bearing parentheticals (e.g. "(Live)") are left alone: their
    /// versions genuinely differ, and the duration gate handles the rest.
    public static func cleanTitle(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespaces)
        while true {
            let range = NSRange(result.startIndex..., in: result)
            guard let match = trailingGroup.firstMatch(in: result, range: range),
                  let contentRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result)
            else { break }
            let content = String(result[contentRange])
            guard annotation.firstMatch(
                in: content, range: NSRange(content.startIndex..., in: content)) != nil
            else { break }
            result.removeSubrange(fullRange)
            result = result.trimmingCharacters(in: .whitespaces)
        }

        let range = NSRange(result.startIndex..., in: result)
        if let match = dashSuffix.firstMatch(in: result, range: range),
           let r = Range(match.range, in: result) {
            result.removeSubrange(r)
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return result.isEmpty ? title : result
    }

    // MARK: - Fetch chain (first hit wins; a failure stops the chain)

    private func fetch(artist: String, title: String, album: String, durationS: Int) -> LyricsOutcome {
        let exact = fetchGet(artist: artist, title: title, album: album, durationS: durationS)
        guard exact == .none else { return exact }

        let byArtist = fetchSearch(track: title, artist: artist, durationS: durationS)
        guard byArtist == .none else { return byArtist }

        // Last resort: annotation-free title with no artist filter — covers
        // "(From ...)" movie suffixes and multi-artist strings lrclib stores
        // differently. Duration-gated, so a same-named other song can't match.
        let cleaned = Self.cleanTitle(title)
        if cleaned != title || !artist.isEmpty {
            return fetchSearch(track: cleaned, artist: nil, durationS: durationS,
                               maxDurationDelta: Self.maxDurationDeltaS)
        }
        return .none
    }

    /// Exact lookup: GET /api/get?artist_name=&track_name=&album_name=&duration=
    private func fetchGet(artist: String, title: String, album: String, durationS: Int) -> LyricsOutcome {
        var comps = URLComponents(string: Self.base + "/api/get")!
        comps.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(durationS)),
        ]
        do {
            let (status, body) = try httpGet(comps.url!)
            // Only 404 means "lrclib has no such track". 5xx et al. are outages
            // and must surface as .unavailable so they are never cached as misses.
            if status == 404 { return .none }
            guard status == 200, !body.isEmpty else { return .unavailable }
            guard let obj = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            else { return .unavailable }
            if let lrc = obj["syncedLyrics"] as? String, !lrc.isEmpty { return .found(lrc) }
            return .none
        } catch {
            return .unavailable
        }
    }

    /// Fallback: GET /api/search, closest duration wins (optionally gated).
    private func fetchSearch(
        track: String, artist: String?, durationS: Int, maxDurationDelta: Int? = nil
    ) -> LyricsOutcome {
        var comps = URLComponents(string: Self.base + "/api/search")!
        var query = [URLQueryItem(name: "track_name", value: track)]
        if let artist, !artist.isEmpty {
            query.append(URLQueryItem(name: "artist_name", value: artist))
        }
        comps.queryItems = query
        do {
            let (status, body) = try httpGet(comps.url!)
            if status == 404 { return .none }
            guard status == 200, !body.isEmpty else { return .unavailable }
            guard let items = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]]
            else { return .unavailable }
            var candidates = items.compactMap { item -> (lrc: String, duration: Int)? in
                guard let lrc = item["syncedLyrics"] as? String, !lrc.isEmpty else { return nil }
                return (lrc, (item["duration"] as? NSNumber)?.intValue ?? 0)
            }
            if let maxDurationDelta {
                candidates = candidates.filter { abs($0.duration - durationS) <= maxDurationDelta }
            }
            guard let best = candidates.min(by: {
                abs($0.duration - durationS) < abs($1.duration - durationS)
            }) else { return .none }
            return .found(best.lrc)
        } catch {
            return .unavailable
        }
    }

    // MARK: - Transport

    // Ephemeral: no CFNetwork disk cache / cookie store — the lyric cache
    // above is the only persistence this client needs.
    private static let session = URLSession(configuration: .ephemeral)

    /// Real HTTPS, identifying itself as lrclib asks clients to. Synchronous —
    /// only ever called on a background queue.
    public static func defaultHttpGet(userAgent: String) -> HttpGet {
        { url in
            var request = URLRequest(url: url, timeoutInterval: requestTimeout)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<(status: Int, body: String), Error> = .failure(URLError(.unknown))
            session.dataTask(with: request) { data, response, error in
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
}
