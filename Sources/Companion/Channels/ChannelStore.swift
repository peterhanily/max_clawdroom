import Foundation
import Observation

extension Notification.Name {
    /// Posted by `ChannelStore` whenever the active channel changes
    /// (switched, edited in place, or removed-and-fallback). Listeners:
    /// `ChatSession` (drops the cached client), `OverlayController`
    /// (applies persona / drives expression), `MenuBarController`
    /// (rebuilds the Channels submenu).
    static let companionActiveChannelChanged =
        Notification.Name("companion.activeChannelChanged")

    /// Posted by `ChatSession` when a stream fails with 401/403 against
    /// a remote channel. Carries `userInfo["channelID"]: String`.
    /// Listeners: `ChannelHealth` (immediate state flip without waiting
    /// for next probe), `MenuBarController` (could surface a re-pair
    /// banner).
    static let companionChannelAuthFailed =
        Notification.Name("companion.channelAuthFailed")
}

/// Single source of truth for the channel list and which one is active.
/// Persists to UserDefaults under `companion.channels.v1` (non-secret
/// fields) + Keychain (per-channel bearer tokens).
@Observable
@MainActor
final class ChannelStore {
    static let shared = ChannelStore()

    private(set) var channels: [Channel]
    private(set) var activeID: UUID

    var active: Channel {
        channels.first(where: { $0.id == activeID }) ?? channels[0]
    }

    @ObservationIgnored private let channelsKey = "companion.channels.v1"
    @ObservationIgnored private let activeKey = "companion.activeChannel.v1"

    private init() {
        let decoded: [Channel]? = {
            guard let data = UserDefaults.standard.data(forKey: "companion.channels.v1") else {
                return nil
            }
            return try? JSONDecoder().decode([Channel].self, from: data)
        }()

        if let decoded, !decoded.isEmpty {
            self.channels = decoded
            if
                let raw = UserDefaults.standard.string(forKey: "companion.activeChannel.v1"),
                let id = UUID(uuidString: raw),
                decoded.contains(where: { $0.id == id })
            {
                self.activeID = id
            } else {
                self.activeID = decoded[0].id
            }
        } else {
            // First launch on a build with channels — synthesise from
            // the legacy `BackendSettings` so the user's existing
            // backend choice is preserved with zero clicks.
            let migrated = ChannelMigration.bootstrapFromLegacySettings()
            self.channels = migrated
            self.activeID = migrated[0].id
            // Persist immediately so a crash before first edit still
            // leaves a valid channel list on disk.
            persist()
        }
    }

    // MARK: - Mutators

    func add(_ channel: Channel) {
        channels.append(channel)
        persist()
        NotificationCenter.default.post(name: .companionActiveChannelChanged, object: nil)
    }

    func update(_ channel: Channel) {
        guard let idx = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        channels[idx] = channel
        persist()
        if channel.id == activeID {
            NotificationCenter.default.post(name: .companionActiveChannelChanged, object: nil)
        }
    }

    /// Remove a channel. If it was active, fall back to the first
    /// remaining channel. Tokens in Keychain are deleted alongside.
    /// The last channel cannot be removed — there must always be at
    /// least one to drive `clientOrBuild`.
    func remove(id: UUID) {
        guard channels.count > 1 else { return }
        guard let idx = channels.firstIndex(where: { $0.id == id }) else { return }
        let removed = channels.remove(at: idx)
        if removed.authRef == .bearerInKeychain {
            KeychainStore.write(account: KeychainStore.bearerAccount(for: removed.id), value: "")
        }
        let activeChanged = (id == activeID)
        if activeChanged {
            activeID = channels[0].id
        }
        persist()
        if activeChanged {
            NotificationCenter.default.post(name: .companionActiveChannelChanged, object: nil)
        }
    }

    func setActive(id: UUID) {
        guard channels.contains(where: { $0.id == id }) else { return }
        guard id != activeID else { return }
        activeID = id
        persist()
        NotificationCenter.default.post(name: .companionActiveChannelChanged, object: nil)
    }

    // MARK: - Bearer helpers

    /// Fetch the bearer token for a channel from Keychain. Returns nil
    /// when no token is stored or the channel doesn't use one.
    func bearer(for id: UUID) -> String? {
        guard let ch = channels.first(where: { $0.id == id }),
              ch.authRef == .bearerInKeychain
        else { return nil }
        let v = KeychainStore.read(account: KeychainStore.bearerAccount(for: id))
        return v.isEmpty ? nil : v
    }

    /// Persist a bearer for a channel and flip its `authRef` to
    /// `.bearerInKeychain` if it wasn't already. Use this from the
    /// pair / paste flows so callers don't have to write Keychain
    /// directly.
    func setBearer(_ token: String, for id: UUID) {
        guard let idx = channels.firstIndex(where: { $0.id == id }) else { return }
        KeychainStore.write(account: KeychainStore.bearerAccount(for: id), value: token)
        if channels[idx].authRef != .bearerInKeychain {
            channels[idx].authRef = .bearerInKeychain
            persist()
        }
        if id == activeID {
            NotificationCenter.default.post(name: .companionActiveChannelChanged, object: nil)
        }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(channels)
            UserDefaults.standard.set(data, forKey: channelsKey)
            UserDefaults.standard.set(activeID.uuidString, forKey: activeKey)
        } catch {
            AppLog.settings.error("encode failure — channels NOT saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
