import Foundation

/// Resolves a free-text query into a myinstants.com MP3 URL by hitting
/// the public search page and extracting the first result's media URL.
///
/// Nothing is bundled, nothing is hosted; we're a pure user-agent that
/// names a URL Max already knows about. Same legal posture as a browser
/// loading the page on the user's behalf. The actual playback then runs
/// through `RemoteAudioFetcher` → `SoundEngine`, which inherits all of
/// that path's safeguards (size cap, content-type check, in-memory
/// only, gated by `Prefs.allowAgentAudioFetch`).
///
/// myinstants.com is HTML-scraped — there is no documented API. The
/// regex matches the inline `onclick="play('/media/sounds/<slug>.mp3', …)"`
/// pattern that's been stable for the life of the site. If the markup
/// changes, the resolver returns nil and the action no-ops cleanly.
enum MyInstantsLookup {
    enum LookupError: LocalizedError {
        case disabledByPref
        case badQuery
        case noResults
        case http(Int)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .disabledByPref: return "Remote audio fetch is disabled (Settings → Voice & Look → Sound effects → Allow agent audio fetch)."
            case .badQuery:       return "Empty search query."
            case .noResults:      return "No results on myinstants for that query."
            case .http(let c):    return "myinstants returned HTTP \(c)"
            case .transport(let m): return "Network error: \(m)"
            }
        }
    }

    /// Search myinstants for `query` and call `completion` on a
    /// background queue with the first MP3 URL (or an error).
    /// Completion-handler API rather than async/await — see the note
    /// in `RemoteAudioFetcher.fetch`.
    /// Pref-gating happens at the @MainActor caller (SoundEngine);
    /// this function is nonisolated so the URLSession completion
    /// closure can call it without crossing actor boundaries.
    nonisolated static func resolveFirstMP3(
        query: String,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(LookupError.badQuery))
            return
        }

        var components = URLComponents(string: "https://www.myinstants.com/en/search/")!
        components.queryItems = [URLQueryItem(name: "name", value: trimmed)]
        guard let url = components.url else {
            completion(.failure(LookupError.badQuery))
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("max_clawdroom/1.0 (audio search)", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(LookupError.transport(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(LookupError.transport("non-HTTP response")))
                return
            }
            if !(200..<300).contains(http.statusCode) {
                completion(.failure(LookupError.http(http.statusCode)))
                return
            }
            // 1MB cap on the search page — myinstants results page is
            // ~50KB; anything bigger is suspect (mirror, redirect trap).
            if data.count > 1_000_000 {
                completion(.failure(LookupError.transport("oversize search response")))
                return
            }
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            guard let mp3Path = firstMP3Path(in: html) else {
                completion(.failure(LookupError.noResults))
                return
            }
            guard let resolved = URL(
                string: mp3Path,
                relativeTo: URL(string: "https://www.myinstants.com")!
            )?.absoluteURL else {
                completion(.failure(LookupError.noResults))
                return
            }
            completion(.success(resolved))
        }
        task.resume()
    }

    /// Single regex extraction. `try!` is safe because the pattern is
    /// a constant validated at compile-time-by-test.
    private static let mp3Pattern: NSRegularExpression = {
        // play('  /media/sounds/...  .mp3  '
        try! NSRegularExpression(
            pattern: #"play\(\s*'(/media/sounds/[^']+\.mp3)'"#,
            options: []
        )
    }()

    private static func firstMP3Path(in html: String) -> String? {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let m = mp3Pattern.firstMatch(in: html, range: range),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: html)
        else { return nil }
        return String(html[r])
    }
}
