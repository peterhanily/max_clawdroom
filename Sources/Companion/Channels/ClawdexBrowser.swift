import Foundation
import Network
import Observation

/// One discovered Clawdex `--lan` host on the local network. The
/// `endpoint` is what `ClawdexPairing.resolve` consumes to turn the
/// Bonjour name into a concrete `host:port`.
struct DiscoveredClawdex: Identifiable, Hashable {
    let id: String              // Bonjour service name acts as id
    let displayName: String     // "clawdex@studio-imac"
    let endpoint: NWEndpoint
}

/// Wraps `NWBrowser` for `_companion._tcp.` filtered on the
/// `role=mac-bridge` TXT record clawdex sets in `--lan` mode. Lifecycle
/// is owned by the AddChannel sheet — `start()` on appear, `stop()` on
/// dismiss.
@Observable
@MainActor
final class ClawdexBrowser {
    private(set) var hosts: [DiscoveredClawdex] = []
    private(set) var error: String?

    @ObservationIgnored private var browser: NWBrowser?

    deinit {
        browser?.cancel()
    }

    func start() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: "_companion._tcp.",
            domain: nil
        )
        let b = NWBrowser(for: descriptor, using: params)
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed(let err) = state {
                    self.error = err.localizedDescription
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let mapped: [DiscoveredClawdex] = results.compactMap { result in
                guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint
                else { return nil }
                // Only surface clawdex-as-mac-bridge instances. The TV
                // companion shares the same service type so the role
                // TXT is the discriminator.
                if case let .bonjour(record) = result.metadata {
                    if record["role"] != "mac-bridge" {
                        return nil
                    }
                }
                return DiscoveredClawdex(
                    id: name,
                    displayName: name,
                    endpoint: result.endpoint
                )
            }
            Task { @MainActor in
                guard let self else { return }
                self.hosts = mapped
            }
        }
        browser = b
        b.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        hosts = []
        error = nil
    }
}
