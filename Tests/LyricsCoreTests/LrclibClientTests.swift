import Foundation
import LyricsCore

/// Records URLs requested; returns queued (status, body) responses.
private final class FakeHttp {
    private var responses: [(Int, String)]
    private(set) var urls: [String] = []
    private let reporter: TestReporter

    init(_ responses: [(Int, String)], reporter: TestReporter) {
        self.responses = responses
        self.reporter = reporter
    }

    func get(_ url: URL) throws -> (status: Int, body: String) {
        urls.append(url.absoluteString)
        guard !responses.isEmpty else {
            reporter.expect(false, "lrclib: unexpected extra HTTP request: \(url)")
            return (599, "")
        }
        return responses.removeFirst()
    }
}

private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lrclib-tests-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func withClient(
    _ http: @escaping LrclibClient.HttpGet, body: (LrclibClient, URL) -> Void
) {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    body(LrclibClient(cacheDir: dir, httpGet: http), dir)
}

// A definitive miss burns three requests: /api/get, /api/search with artist,
// then the artist-less cleaned-title search.
private let missChain: [(Int, String)] = [(404, ""), (200, "[]"), (200, "[]")]

func lrclibClientTests(_ t: TestReporter) {
    do {
        let http = FakeHttp([(200, #"{"syncedLyrics": "[00:01.00] hi"}"#)], reporter: t)
        withClient(http.get) { client, _ in
            t.expect(
                client.getSynced(artist: "Artist", title: "Song", album: "Album", durationS: 200)
                    == .found("[00:01.00] hi"),
                "lrclib: /api/get returns synced lyrics")
            t.expect(http.urls[0].contains("/api/get?"), "lrclib: first request hits /api/get")
            t.expect(http.urls[0].contains("duration=200"), "lrclib: duration in query")
        }
    }

    do {
        let search = """
        [{"syncedLyrics": "[00:00.00] wrong", "duration": 100},
         {"syncedLyrics": "[00:00.00] right", "duration": 201}]
        """
        // First response consumed by /api/get, second by the /api/search fallback.
        let http = FakeHttp([(404, ""), (200, search)], reporter: t)
        withClient(http.get) { client, _ in
            // Closest duration to 200 is the 201 item.
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
                    == .found("[00:00.00] right"),
                "lrclib: 404 falls back to search by duration")
            t.expect(http.urls.count == 2 && http.urls[1].contains("/api/search?"),
                     "lrclib: fallback hits /api/search")
        }
    }

    do {
        let http = FakeHttp([(200, #"{"syncedLyrics": null}"#), (200, "[]"), (200, "[]")],
                            reporter: t)
        withClient(http.get) { client, _ in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200) == .none,
                "lrclib: no synced lyrics anywhere returns .none")
        }
    }

    do {
        withClient({ _ in throw URLError(.notConnectedToInternet) }) { client, _ in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
                    == .unavailable,
                "lrclib: network error returns .unavailable")
        }
    }

    do {
        // A parse failure aborts without hitting the fallbacks (one request only).
        let http = FakeHttp([(200, "not-json")], reporter: t)
        withClient(http.get) { client, _ in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
                    == .unavailable,
                "lrclib: malformed JSON returns .unavailable")
            t.expect(http.urls.count == 1, "lrclib: malformed JSON makes no fallback request")
        }
    }

    do {
        let http = FakeHttp([(200, #"{"syncedLyrics": "[00:01.00] cached"}"#)], reporter: t)
        withClient(http.get) { client, _ in
            let first = client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
            // Second call: no queued responses left; must come from cache.
            let second = client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
            t.expect(first == second && first == .found("[00:01.00] cached"),
                     "lrclib: cache hit returns same lyrics")
            t.expect(http.urls.count == 1, "lrclib: cache hit skips HTTP")
        }
    }

    do {
        let http = FakeHttp(missChain, reporter: t)
        withClient(http.get) { client, _ in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200) == .none,
                "lrclib: definitive miss returns .none")
            // Cached miss inside the TTL: no further requests.
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200) == .none,
                "lrclib: cached miss returns .none")
            t.expect(http.urls.count == 3, "lrclib: miss is cached (no re-fetch)")
        }
    }

    do {
        var failFirst = true
        let http = FakeHttp([(200, #"{"syncedLyrics": "[00:01.00] back online"}"#)], reporter: t)
        let flaky: LrclibClient.HttpGet = { url in
            if failFirst {
                failFirst = false
                throw URLError(.notConnectedToInternet)
            }
            return try http.get(url)
        }
        withClient(flaky) { client, _ in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
                    == .unavailable,
                "lrclib: transient failure returns .unavailable")
            // Transient failure was not cached as a miss — the retry succeeds.
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
                    == .found("[00:01.00] back online"),
                "lrclib: transient failure is not cached")
        }
    }

    do {
        // Cached miss older than the TTL is re-fetched (fresh releases gain
        // lyrics on lrclib over time).
        let http = FakeHttp(missChain + [(200, #"{"syncedLyrics": "[00:01.00] late add"}"#)],
                            reporter: t)
        withClient(http.get) { client, dir in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200) == .none,
                "lrclib: TTL test primes a miss")
            let missFile = try! FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)[0]
            try! FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -25 * 3600)],
                ofItemAtPath: missFile.path)
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
                    == .found("[00:01.00] late add"),
                "lrclib: expired miss is re-fetched")
        }
    }

    do {
        // Annotated title: exact get and artist search miss; the cleaned,
        // artist-less search lands it.
        let cleanedHit = #"[{"syncedLyrics": "[00:01.00] found it", "duration": 204}]"#
        let http = FakeHttp([(404, ""), (200, "[]"), (200, cleanedHit)], reporter: t)
        withClient(http.get) { client, _ in
            t.expect(
                client.getSynced(artist: "Anirudh Ravichander",
                                 title: #"Yennai Maatrum Kadhale (From "Naanum Rowdy Dhaan")"#,
                                 album: "X", durationS: 200)
                    == .found("[00:01.00] found it"),
                "lrclib: cleaned-title fallback finds annotated tracks")
            t.expect(http.urls.count == 3
                     && http.urls[2].contains("track_name=Yennai%20Maatrum%20Kadhale")
                     && !http.urls[2].contains("artist_name"),
                     "lrclib: third request is cleaned title without artist")
        }
    }

    do {
        // The artist-less fallback is duration-gated: a same-named song 100 s
        // off must not match.
        let farHit = #"[{"syncedLyrics": "[00:01.00] wrong song", "duration": 300}]"#
        let http = FakeHttp([(404, ""), (200, "[]"), (200, farHit)], reporter: t)
        withClient(http.get) { client, _ in
            t.expect(
                client.getSynced(artist: "A", title: "S (feat. B)", album: "Al", durationS: 200)
                    == .none,
                "lrclib: duration gate rejects far matches in cleaned search")
        }
    }

    // cleanTitle unit cases
    t.expect(LrclibClient.cleanTitle(#"Yennai Maatrum Kadhale (From "Naanum Rowdy Dhaan")"#)
             == "Yennai Maatrum Kadhale", "cleanTitle: (From \"Movie\") stripped")
    t.expect(LrclibClient.cleanTitle("Song (feat. Artist)") == "Song",
             "cleanTitle: (feat. X) stripped")
    t.expect(LrclibClient.cleanTitle("Song [ft. A] (From \"B\")") == "Song",
             "cleanTitle: stacked annotations stripped")
    t.expect(LrclibClient.cleanTitle("Track - From \"Movie Name\"") == "Track",
             "cleanTitle: dash From suffix stripped")
    t.expect(LrclibClient.cleanTitle("Let It Be (Remastered 2009)") == "Let It Be",
             "cleanTitle: remaster tag stripped")
    t.expect(LrclibClient.cleanTitle("Alive (Live)") == "Alive (Live)",
             "cleanTitle: live version kept — different lyrics timing")
    t.expect(LrclibClient.cleanTitle("(Everything I Do) I Do It for You")
             == "(Everything I Do) I Do It for You",
             "cleanTitle: leading parenthetical kept")
    t.expect(LrclibClient.cleanTitle(#"(From "X")"#) == #"(From "X")"#,
             "cleanTitle: never returns an empty title")
}
