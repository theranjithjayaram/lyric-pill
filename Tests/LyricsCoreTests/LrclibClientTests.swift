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

private func withClient(
    _ http: @escaping LrclibClient.HttpGet, body: (LrclibClient) -> Void
) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lrclib-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    body(LrclibClient(cacheDir: dir, httpGet: http))
}

func lrclibClientTests(_ t: TestReporter) {
    do {
        let http = FakeHttp([(200, #"{"syncedLyrics": "[00:01.00] hi"}"#)], reporter: t)
        withClient(http.get) { client in
            t.expect(
                client.getSynced(artist: "Artist", title: "Song", album: "Album", durationS: 200)
                    == "[00:01.00] hi",
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
        withClient(http.get) { client in
            // Closest duration to 200 is the 201 item.
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
                    == "[00:00.00] right",
                "lrclib: 404 falls back to search by duration")
            t.expect(http.urls.count == 2 && http.urls[1].contains("/api/search?"),
                     "lrclib: fallback hits /api/search")
        }
    }

    do {
        let http = FakeHttp([(200, #"{"syncedLyrics": null}"#), (200, "[]")], reporter: t)
        withClient(http.get) { client in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200) == nil,
                "lrclib: no synced lyrics returns nil")
        }
    }

    do {
        withClient({ _ in throw URLError(.notConnectedToInternet) }) { client in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200) == nil,
                "lrclib: network error returns nil")
        }
    }

    do {
        // A parse failure aborts without hitting the search fallback (one request only).
        let http = FakeHttp([(200, "not-json")], reporter: t)
        withClient(http.get) { client in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200) == nil,
                "lrclib: malformed JSON returns nil")
            t.expect(http.urls.count == 1, "lrclib: malformed JSON makes no fallback request")
        }
    }

    do {
        let http = FakeHttp([(200, #"{"syncedLyrics": "[00:01.00] cached"}"#)], reporter: t)
        withClient(http.get) { client in
            let first = client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
            // Second call: no queued responses left; must come from cache.
            let second = client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
            t.expect(first == second && first != nil, "lrclib: cache hit returns same lyrics")
            t.expect(http.urls.count == 1, "lrclib: cache hit skips HTTP")
        }
    }

    do {
        let http = FakeHttp([(404, ""), (200, "[]")], reporter: t)
        withClient(http.get) { client in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200) == nil,
                "lrclib: definitive miss returns nil")
            // Cached miss: no further requests.
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200) == nil,
                "lrclib: cached miss returns nil")
            t.expect(http.urls.count == 2, "lrclib: miss is cached (no re-fetch)")
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
        withClient(flaky) { client in
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200) == nil,
                "lrclib: transient failure returns nil")
            // Transient failure was not cached as a miss — the retry succeeds.
            t.expect(
                client.getSynced(artist: "A", title: "S", album: "Al", durationS: 200)
                    == "[00:01.00] back online",
                "lrclib: transient failure is not cached")
        }
    }
}
