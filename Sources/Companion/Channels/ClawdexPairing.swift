import Foundation
import Network

/// Helpers for discovering a Clawdex `--lan` host on the local network,
/// resolving the Bonjour service to a concrete `host:port`, and trading
/// a 6-digit pairing code for a bearer token.
///
/// Ported from the TV companion (`MaxClawdroomKit/Backends/ClawdexPairing.swift`)
/// — clawdex's pair endpoint is identical for the Mac client, so we reuse
/// the same handshake.
///
/// Deliberately not @MainActor — `NWConnection` resolves on its own
/// queue and `URLSession` likewise; the @MainActor onboarding view
/// awaits these.
enum ClawdexPairing {
    enum PairError: LocalizedError {
        case resolveFailed(String)
        case transportFailed(String)
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .resolveFailed(let m): return "Couldn't reach Clawdex: \(m)"
            case .transportFailed(let m): return "Network error: \(m)"
            case .rejected(let m): return m
            }
        }
    }

    /// Open a short-lived `NWConnection` against the Bonjour-discovered
    /// service long enough for mDNS to resolve the underlying IP/port,
    /// then tear it down. URLSession needs a concrete URL; Bonjour
    /// names aren't URL-safe directly.
    nonisolated static func resolve(
        endpoint: NWEndpoint,
        timeout: TimeInterval = 4.0
    ) async throws -> (host: String, port: Int) {
        let box = ResolveBox()
        return try await withCheckedThrowingContinuation { cont in
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let connection = NWConnection(to: endpoint, using: params)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let remote = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = remote {
                        let hostString = Self.unwrap(host: host)
                        box.settle(
                            result: .success((hostString, Int(port.rawValue))),
                            cont: cont, connection: connection
                        )
                    } else if case .hostPort(let host, let port) = endpoint {
                        let hostString = Self.unwrap(host: host)
                        box.settle(
                            result: .success((hostString, Int(port.rawValue))),
                            cont: cont, connection: connection
                        )
                    } else {
                        box.settle(
                            result: .failure(PairError.resolveFailed("no remote endpoint")),
                            cont: cont, connection: connection
                        )
                    }
                case .failed(let err):
                    box.settle(
                        result: .failure(PairError.resolveFailed(err.localizedDescription)),
                        cont: cont, connection: connection
                    )
                case .cancelled:
                    box.settle(
                        result: .failure(PairError.resolveFailed("cancelled")),
                        cont: cont, connection: connection
                    )
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.settle(
                    result: .failure(PairError.resolveFailed("timeout")),
                    cont: cont, connection: connection
                )
            }
        }
    }

    /// Lock-protected one-shot continuation completer. Pairs with the
    /// NWConnection state callback so we never double-resume under
    /// Swift 6 strict concurrency.
    nonisolated private final class ResolveBox: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        func settle(
            result: Result<(host: String, port: Int), Error>,
            cont: CheckedContinuation<(host: String, port: Int), Error>,
            connection: NWConnection
        ) {
            lock.lock()
            if settled { lock.unlock(); return }
            settled = true
            lock.unlock()
            connection.cancel()
            cont.resume(with: result)
        }
    }

    /// POST /pair with the 6-digit code. Returns the bearer token on
    /// accept, throws `PairError.rejected` on the wrong code, etc.
    nonisolated static func pair(
        host: String,
        port: Int,
        pairingCode: String,
        deviceName: String
    ) async throws -> (token: String, serverName: String) {
        guard let url = URL(string: "http://\(host):\(port)/pair") else {
            throw PairError.transportFailed("bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: String] = [
            "pairing_code": pairingCode,
            "device_name": deviceName
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PairError.transportFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PairError.transportFailed("non-HTTP response")
        }
        if http.statusCode == 401 {
            if let err = try? JSONDecoder().decode(ServerError.self, from: data) {
                throw PairError.rejected(err.error.message)
            }
            throw PairError.rejected("Wrong pairing code")
        }
        if http.statusCode == 429 {
            throw PairError.rejected("Too many tries — wait a minute and try again.")
        }
        if !(200..<300).contains(http.statusCode) {
            throw PairError.transportFailed("HTTP \(http.statusCode)")
        }
        guard let ok = try? JSONDecoder().decode(PairOK.self, from: data) else {
            throw PairError.transportFailed("couldn't decode pair response")
        }
        return (ok.token, ok.server_name)
    }

    // MARK: - Internals

    nonisolated private static func unwrap(host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let addr):    return addr.debugDescription
        case .ipv6(let addr):    return "[\(addr.debugDescription)]"
        case .name(let name, _): return name
        @unknown default:        return "\(host)"
        }
    }

    nonisolated private struct PairOK: Decodable {
        let token: String
        let server_name: String
    }
    nonisolated private struct ServerError: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }
}
