import Foundation

/// Periodic weather snapshot grounding the agent in the user's actual
/// outside world. Pulls from `wttr.in` (a free, public, no-key weather
/// proxy that uses the request IP for geolocation when no location is
/// supplied) so we don't need WeatherKit, an Apple Developer Program
/// membership, or a `NSLocationUsageDescription` TCC prompt.
///
/// **Trade-off.** IP-based location is approximate (city or ISP-region
/// granularity) and wttr.in is third-party. Both consequences are
/// disclosed via the opt-in pref — `Prefs.weatherEnabled` defaults off
/// because pulling weather makes a network call to a non-Apple service
/// even when no chat is active. When off, this whole file is dormant
/// (no observers, no requests).
///
/// **Cache.** wttr.in is rate-limited per-IP and the data only changes
/// on a minutes scale. We cache results for 30 minutes; consumers
/// (`EnvironmentSensors.contextSnapshot`) read the cached value
/// synchronously and only trigger a refresh when stale.
@MainActor
final class WeatherSensor {

    static let shared = WeatherSensor()

    /// Cached snapshot. Nil before the first successful fetch; stays
    /// populated across pref toggles so a re-enable can reuse the last
    /// fresh value rather than block the next env-block render on a
    /// cold network call.
    private(set) var cached: WeatherSnapshot?
    private var fetchInFlight = false
    private let staleAfter: TimeInterval = 30 * 60

    /// Snapshot the env builder folds into the `[world]` block. Kept
    /// terse — the agent is supposed to *ground* on this, not recite it.
    struct WeatherSnapshot: Sendable {
        let condition: String       // "Sunny", "Light rain", "Snow showers"
        let temperatureC: Int
        let temperatureF: Int
        let location: String        // best-effort city / region name
        let fetchedAt: Date
    }

    private init() {}

    /// Returns the cached snapshot when available. Triggers an async
    /// refresh when missing or older than `staleAfter`. Caller renders
    /// without waiting — the next env block picks up the updated value.
    func snapshotForEnvBlock() -> WeatherSnapshot? {
        guard Prefs.weatherEnabled else { return nil }
        if let c = cached, Date().timeIntervalSince(c.fetchedAt) < staleAfter {
            return c
        }
        refresh()
        return cached     // may still be nil on cold start
    }

    /// Explicit refresh trigger — called on enable so the first env
    /// block after the toggle isn't empty.
    func refresh() {
        guard Prefs.weatherEnabled, !fetchInFlight else { return }
        fetchInFlight = true
        Task.detached(priority: .background) { [weak self] in
            let snap = await Self.fetch()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fetchInFlight = false
                if let snap {
                    self.cached = snap
                    AppLog.app.notice("WeatherSensor: refreshed (\(snap.condition, privacy: .public), \(snap.temperatureC, privacy: .public)°C in \(snap.location, privacy: .public))")
                }
            }
        }
    }

    /// One-shot fetch against wttr.in's JSON endpoint. Returns nil on
    /// any failure (network, decode, schema drift) — weather grounding
    /// is best-effort, never load-bearing. 8-second timeout so a stuck
    /// network doesn't pin the background task forever.
    nonisolated private static func fetch() async -> WeatherSnapshot? {
        guard let url = URL(string: "https://wttr.in/?format=j1") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        // Lie about the User-Agent — wttr.in's default behaviour for
        // browser UAs is to return HTML; we want the JSON path. Their
        // docs recommend "curl/" prefix UAs to force the text/JSON
        // formatters.
        req.setValue("curl/8.0 max_clawdroom", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return parse(data)
        } catch {
            return nil
        }
    }

    nonisolated private static func parse(_ data: Data) -> WeatherSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        guard
            let currents = (root["current_condition"] as? [[String: Any]])?.first,
            let nearest = (root["nearest_area"] as? [[String: Any]])?.first
        else { return nil }
        // wttr.in nests display values inside `[{"value": "..."}]` lists.
        let condition = ((currents["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? "Unknown"
        let tempC = Int((currents["temp_C"] as? String).flatMap(Double.init) ?? 0)
        let tempF = Int((currents["temp_F"] as? String).flatMap(Double.init) ?? 0)
        let area = ((nearest["areaName"] as? [[String: Any]])?.first?["value"] as? String) ?? ""
        let region = ((nearest["region"] as? [[String: Any]])?.first?["value"] as? String) ?? ""
        let location = [area, region].filter { !$0.isEmpty }.joined(separator: ", ")
        return WeatherSnapshot(
            condition: condition,
            temperatureC: tempC,
            temperatureF: tempF,
            location: location,
            fetchedAt: Date()
        )
    }
}
