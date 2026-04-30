import AppKit
import Combine
import Foundation

/// Watches the system Now Playing state (Music.app, Spotify, podcast
/// players, browser audio sessions that publish to MPNowPlayingInfo) and
/// publishes track changes + a tempo-shaped continuous signal onto the
/// `TelemetryBus`. The body's `BindingEngine` then drives any agent-bound
/// part (tie, suit, shoe) in time to whatever's playing.
///
/// **How it works.** macOS exposes Now Playing through the private
/// `MediaRemote.framework`. We `dlopen` it lazily — no link-time
/// dependency, no entitlement, no TCC prompt. If the symbols aren't
/// present (future macOS removes the framework, or the user denies
/// loading on a hardened install), the observer silently no-ops; the
/// body just doesn't react to music. The framework has been stable
/// across macOS 10.12.2 → present and is the same surface every shipping
/// "now playing" utility uses (NepTunes, MusicHarbor, Sleeve, etc).
///
/// **Lifecycle.** `start()` registers for the change notification; we
/// poll `getNowPlayingInfo` on each notification (and once at start)
/// and publish only when the title or play-state actually changes.
/// `stop()` removes the observer; the framework hold is released by
/// arc'd refs but the dlopen handle is intentionally never closed —
/// re-loading on every toggle is wasteful.
///
/// **Tempo estimate.** Apple's metadata sometimes carries `kMRMediaRemoteNowPlayingInfoBPM`
/// (Music.app does for tagged tracks); when present we map BPM 60..180
/// onto 0..1. Otherwise we use a crude proxy: playback rate × a fixed
/// 0.55 baseline so the binding has *something* to drive. A future
/// version could run AVAudioEngine on a loopback device for real beat
/// detection; the binding contract stays the same.
@MainActor
final class NowPlayingObserver {

    static let shared = NowPlayingObserver()

    private weak var bus: TelemetryBus?
    private var observer: NSObjectProtocol?
    private var lastTitle: String?
    private var lastIsPlaying: Bool?

    /// Lazily-loaded MediaRemote symbols. Nil when dlopen fails (which
    /// is rare; the framework ships with macOS) or when Apple changes
    /// the symbol names in a future release. All call sites guard.
    private struct MediaRemoteSymbols {
        let getNowPlayingInfo: @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        let registerForNotifications: @convention(c) (DispatchQueue) -> Void
    }
    private static let symbols: MediaRemoteSymbols? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_LAZY
        ) else {
            AppLog.app.notice("NowPlayingObserver: MediaRemote dlopen failed — music-reactive disabled")
            return nil
        }
        guard let getInfoPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo"),
              let registerPtr = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications")
        else {
            AppLog.app.notice("NowPlayingObserver: MediaRemote symbols missing — music-reactive disabled")
            return nil
        }
        typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
        typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
        return MediaRemoteSymbols(
            getNowPlayingInfo: unsafeBitCast(getInfoPtr, to: GetInfoFn.self),
            registerForNotifications: unsafeBitCast(registerPtr, to: RegisterFn.self)
        )
    }()

    private init() {}

    /// Begin watching Now Playing. No-op when MediaRemote is unavailable
    /// or the observer is already running. Wires onto the supplied bus
    /// so multi-overlay setups all share one observer (nudges go through
    /// the bus, not per-overlay subscriptions).
    func start(bus: TelemetryBus) {
        guard Self.symbols != nil else { return }
        if observer != nil { return }
        self.bus = bus

        Self.symbols!.registerForNotifications(.main)
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        // Seed an initial snapshot so the first turn after enabling sees
        // current state without waiting for the user to skip a track.
        refresh()
        AppLog.app.notice("NowPlayingObserver: started")
    }

    func stop() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
        }
        observer = nil
        bus = nil
        lastTitle = nil
        lastIsPlaying = nil
    }

    private func refresh() {
        guard let symbols = Self.symbols, let bus else { return }
        symbols.getNowPlayingInfo(.main) { [weak self] info in
            Task { @MainActor [weak self] in
                self?.publishIfChanged(info: info, bus: bus)
            }
        }
    }

    private func publishIfChanged(info: [String: Any], bus: TelemetryBus) {
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
        let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        let isPlaying = rate > 0
        let bpm = info["kMRMediaRemoteNowPlayingInfoBPM"] as? Double

        // Track change — emit discrete event with payload so the agent
        // can read what's playing on the next turn (via `[env]` or a
        // future `[music]` block).
        if title != lastTitle, let title {
            lastTitle = title
            bus.emit(
                signal: TelemetrySignal.musicTrackChanged,
                value: nil,
                payload: [
                    "title": title,
                    "artist": artist ?? "",
                    "album": album ?? ""
                ]
            )
        }

        // Play-state toggle — discrete.
        if lastIsPlaying != isPlaying {
            lastIsPlaying = isPlaying
            bus.emit(
                signal: TelemetrySignal.musicPlayState,
                value: isPlaying ? 1 : 0,
                payload: ["playing": isPlaying]
            )
        }

        // Tempo signal — continuous, normalised to [0, 1]. BPM range
        // 60..180 covers ballads → drum'n'bass; outside that we clamp.
        // When BPM isn't in the metadata we fall back to a constant
        // mid-tempo so bound parts have *something* to react to whenever
        // music is playing at all.
        if isPlaying {
            let normalised: Double
            if let bpm {
                let clamped = max(60.0, min(180.0, bpm))
                normalised = (clamped - 60.0) / 120.0
            } else {
                normalised = 0.55
            }
            bus.emit(signal: TelemetrySignal.musicTempo, value: normalised)
        } else {
            bus.emit(signal: TelemetrySignal.musicTempo, value: 0)
        }
    }
}
