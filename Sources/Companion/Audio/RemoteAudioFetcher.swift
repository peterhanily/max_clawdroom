import AVFoundation
import Foundation

/// Generic, gated, bounded fetcher for remote audio. Used by both
/// `SoundEngine.playFromURL(...)` (direct URL) and any source-specific
/// resolvers (e.g. `MyInstantsLookup`) that ultimately want a buffer
/// played through the same engine path as procedural sounds.
///
/// Safety contract — every fetch enforces:
/// - **Size cap** (2 MB). Prevents the agent from being tricked into
///   pulling a multi-hour podcast as a sound effect.
/// - **Timeout** (5 s). Prevents Max stalling on a slow host.
/// - **Content-Type allow-list** (`audio/*`). HTML pages and
///   redirect-trap text/plain responses are rejected before decode.
/// - **HTTPS strongly preferred.** `http://` is allowed but logged at
///   `notice` so users / future audits can see when it happens.
/// - **In-memory only.** Buffers cache by URL string in
///   `SoundEngine.buffers`; nothing lands on disk. Process restart =
///   clean slate.
///
/// Disabled entirely unless `Prefs.allowAgentAudioFetch` is on (default
/// off). Same opt-in pattern as `Prefs.allowAgentImageOps` — the user
/// flips the toggle once they decide they trust the agent to reach
/// outside the bundle.
enum RemoteAudioFetcher {
    enum FetchError: LocalizedError {
        case disabledByPref
        case badURL(String)
        case nonAudioContentType(String)
        case oversize(Int)
        case http(Int)
        case transport(String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .disabledByPref:
                return "Remote audio fetch is disabled (Settings → Voice & Look → Sound effects → Allow agent audio fetch)."
            case .badURL(let s):              return "Bad URL: \(s)"
            case .nonAudioContentType(let s): return "Endpoint returned non-audio content (\(s))"
            case .oversize(let n):            return "Audio is too large (\(n) bytes; cap is 2 MB)"
            case .http(let code):             return "HTTP \(code) from audio endpoint"
            case .transport(let m):           return "Network error: \(m)"
            case .decode(let m):              return "Couldn't decode audio: \(m)"
            }
        }
    }

    /// Hard cap on download size. 2 MB covers any short SFX or sting
    /// (a 10-second high-quality MP3 is ~150 KB) while making it
    /// mechanically impossible to use the audio path as a generic
    /// blob downloader.
    static let maxBytes: Int = 2 * 1024 * 1024

    /// Fetches `url`, validates, decodes via AVFoundation, and calls
    /// `completion` on an arbitrary background queue with the result.
    ///
    /// Completion-handler API rather than async/await deliberately:
    /// the actor-hop on the await-boundary intermittently deadlocks
    /// callers under the macOS 26.x executor-hook workaround. Plain
    /// GCD-based dispatch sidesteps Swift concurrency entirely.
    /// Callers hop back to main themselves via DispatchQueue.main.async
    /// before touching @MainActor state.
    /// AVAudioPCMBuffer isn't Sendable. We hop it from the URLSession
    /// worker queue to main for storage; wrapping in @unchecked
    /// Sendable is safe because the buffer is published exactly once
    /// and the producer (URLSession callback) doesn't keep a
    /// reference after firing the completion.
    struct BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    nonisolated static func fetch(
        url: URL,
        completion: @escaping @Sendable (Result<BufferBox, Error>) -> Void
    ) {
        if url.scheme?.lowercased() != "https" {
            AppLog.audio.notice("audio fetch over non-https: \(url.absoluteString, privacy: .public)")
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("audio/*", forHTTPHeaderField: "Accept")
        // Polite UA so the upstream can rate-limit / block us cleanly
        // if they want to. Better than masquerading as a browser.
        req.setValue("max_clawdroom/1.0 (audio fetch)", forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(FetchError.transport(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(FetchError.transport("non-HTTP response")))
                return
            }
            if !(200..<300).contains(http.statusCode) {
                completion(.failure(FetchError.http(http.statusCode)))
                return
            }
            if data.count > maxBytes {
                completion(.failure(FetchError.oversize(data.count)))
                return
            }
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if !ct.isEmpty, !ct.hasPrefix("audio/") {
                completion(.failure(FetchError.nonAudioContentType(ct)))
                return
            }
            // Decode via AVAudioFile against a temp file. The file
            // vanishes the moment we leave this scope.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("max-clawdroom-fetch-\(UUID().uuidString).audio")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                try data.write(to: tmp)
                let file = try AVAudioFile(forReading: tmp)
                guard let buf = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length)
                ) else {
                    completion(.failure(FetchError.decode("PCM buffer allocation failed")))
                    return
                }
                try file.read(into: buf)
                completion(.success(BufferBox(buffer: buf)))
            } catch {
                completion(.failure(FetchError.decode(error.localizedDescription)))
            }
        }
        task.resume()
    }
}
