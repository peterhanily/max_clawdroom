import Foundation
import Network

/// Local HTTP server that speaks OpenAI Chat Completions on 127.0.0.1:52429,
/// backed by the existing `ClaudeCodeProcess` infrastructure. Replaces the
/// standalone `clawdex` Node proxy — any tool that points at
/// `http://127.0.0.1:52429/v1/chat/completions` (Cursor, Continue, the
/// Python `openai` SDK, shell scripts) now hits max_clawdroom directly.
///
/// Scope — this is the **minimal** port:
///   - POST /v1/chat/completions (streaming SSE + non-streaming JSON)
///   - GET  /v1/models (static list; returns the current Claude model)
///   - GET  /healthz  (liveness check for tooling)
///   - Localhost-only bind (no LAN exposure; no auth needed for loopback)
///   - Per-request claude subprocess (no session reuse yet — simpler
///     lifecycle, higher cold-start but bounded by launch time)
///   - Text content only (tool_calls translation is deferred — Cursor
///     and Continue both handle text replies fine; agentic tool use
///     lives inside max_clawdroom's own chat for now)
///
/// Security: NWListener binds to `.loopback` so only processes on this
/// Mac can connect. No authentication by design — adding bearer auth to
/// a loopback socket is theatre. If LAN mode is ever wanted, that's a
/// follow-up with real pairing-token auth.
nonisolated final class LocalOpenAIServer: @unchecked Sendable {

    static let defaultPort: UInt16 = 52_429
    /// Hard cap on total bytes accumulated for a single request (headers +
    /// body). Legitimate OpenAI Chat Completions payloads are small — a
    /// handful of messages, tool schemas, maybe an image — so 16 MB is
    /// generous. Anything bigger is either a bug or a DoS attempt.
    private static let maxRequestBytes = 16 * 1024 * 1024

    private let port: UInt16
    private let handler: OpenAIChatCompletions
    private var listener: NWListener?
    /// Strong refs to in-flight connections so NWConnection isn't GC'd
    /// before it finishes streaming. Keyed by a monotonic id so we can
    /// reap on close.
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()

    init(port: UInt16 = LocalOpenAIServer.defaultPort, handler: OpenAIChatCompletions) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        // NWListener binds to all interfaces by default. We enforce
        // loopback-only in `handleNewConnection` by checking the remote
        // endpoint — cleaner than wrestling with NWInterface filters.
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "LocalOpenAIServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad port \(port)"])
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        listener.stateUpdateHandler = { state in
            // Any listener failure is surfaced via os_log; the app should
            // keep running even if the server can't bind (port in use).
            AppLog.app.notice("LocalOpenAIServer listener state: \(String(describing: state), privacy: .public)")
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        AppLog.app.notice("LocalOpenAIServer bound on 127.0.0.1:\(self.port, privacy: .public)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let snapshot = connections
        connections.removeAll()
        lock.unlock()
        for conn in snapshot.values {
            conn.cancel()
        }
        AppLog.app.notice("LocalOpenAIServer stopped")
    }

    private func handleNewConnection(_ conn: NWConnection) {
        // Enforce loopback-only. The listener binds to all interfaces
        // (NWListener doesn't have a clean filter API for "this interface
        // only"); we accept the connection, inspect the remote endpoint,
        // and immediately cancel if it's not localhost. Cheap, and means
        // the server can never accidentally expose to LAN even if the
        // NWParameters config is later touched.
        if !Self.isLoopback(conn.endpoint) {
            AppLog.app.notice("LocalOpenAIServer rejecting non-loopback peer: \(String(describing: conn.endpoint), privacy: .public)")
            conn.cancel()
            return
        }

        let key = ObjectIdentifier(conn)
        lock.lock()
        connections[key] = conn
        lock.unlock()

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.lock.lock()
                self?.connections.removeValue(forKey: key)
                self?.lock.unlock()
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        readRequest(on: conn)
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                // 127.0.0.0/8 is loopback.
                return addr.rawValue.first == 127
            case .ipv6(let addr):
                return addr == .loopback
            case .name:
                return false
            @unknown default:
                return false
            }
        default:
            // `.service` / `.unix` etc. — not how HTTP arrives here.
            return false
        }
    }

    /// Read the HTTP request into a single buffer. The protocol parser
    /// here is intentionally small — OpenAI-compatible requests are
    /// well-formed POSTs with a JSON body and Content-Length; we only
    /// handle that shape. Chunked encoding isn't standard for OpenAI
    /// clients so we don't support it.
    private func readRequest(on conn: NWConnection, accumulated: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                AppLog.app.error("LocalOpenAIServer recv error: \(error.localizedDescription, privacy: .public)")
                conn.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            // Reject over-sized requests before we keep reading. Prevents a
            // misbehaving (or malicious) local client from pinning RAM by
            // streaming an unbounded body. 413 matches RFC 9110.
            if buffer.count > Self.maxRequestBytes {
                self.respond(on: conn, status: 413, body: "request too large")
                return
            }
            // Look for end of headers. Body length = Content-Length header.
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    conn.cancel()
                    return
                }
                self.readRequest(on: conn, accumulated: buffer)
                return
            }
            let headerBytes = buffer.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerText = String(data: headerBytes, encoding: .utf8) else {
                self.respond(on: conn, status: 400, body: "bad headers")
                return
            }
            let lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                self.respond(on: conn, status: 400, body: "empty request")
                return
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.respond(on: conn, status: 400, body: "bad request line")
                return
            }
            let method = String(parts[0])
            let path = String(parts[1])
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            }
            // Validate Content-Length. `Int(…) ?? 0` previously silently
            // coerced malformed or absurd values (e.g. "99999…9") to 0,
            // which could mask malformed requests and — on overflow — feed
            // a huge value into the body-size calc. Require a parseable,
            // non-negative, within-cap number. Absent header → treat as 0.
            let contentLengthRaw = headers["content-length"]
            let contentLength: Int
            if let raw = contentLengthRaw {
                guard let parsed = Int(raw), parsed >= 0, parsed <= Self.maxRequestBytes else {
                    self.respond(on: conn, status: 400, body: "invalid content-length")
                    return
                }
                contentLength = parsed
            } else {
                contentLength = 0
            }
            let bodyStart = headerEnd.upperBound
            let bodyHave = buffer.count - bodyStart
            if bodyHave < contentLength && !isComplete {
                self.readRequest(on: conn, accumulated: buffer)
                return
            }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + min(bodyHave, contentLength)))
            self.route(conn: conn, method: method, path: path, headers: headers, body: body)
        }
    }

    private func route(conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        // Path can include a query string; strip it for routing.
        let routePath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path

        if method == "OPTIONS" {
            // Permissive CORS so browser-hosted tools (Continue's web
            // UI, custom dev tools) can call us. Loopback-only bind
            // means this doesn't open attack surface beyond the box.
            respond(on: conn, status: 204, extraHeaders: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization"
            ], body: "")
            return
        }

        switch (method, routePath) {
        case ("GET", "/healthz"):
            respond(on: conn, status: 200, body: "ok")
        case ("GET", "/v1/models"):
            handler.handleModelsList { [weak self] jsonBody in
                self?.respond(on: conn, status: 200, contentType: "application/json", body: jsonBody)
            }
        case ("POST", "/v1/chat/completions"):
            handler.handleChatCompletions(body: body) { [weak self] event in
                guard let self else { return }
                switch event {
                case .nonStreamingJSON(let json):
                    self.respond(on: conn, status: 200, contentType: "application/json", body: json)
                case .startStreaming:
                    self.respondStreamingHeaders(on: conn)
                case .streamChunk(let data):
                    conn.send(content: data, completion: .contentProcessed { _ in })
                case .streamEnd:
                    conn.send(content: Data("data: [DONE]\n\n".utf8), completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                case .error(let status, let message):
                    self.respond(on: conn, status: status, contentType: "application/json",
                                 body: Self.errorJSON(message))
                }
            }
        default:
            respond(on: conn, status: 404, body: "not found")
        }
    }

    private func respond(
        on conn: NWConnection,
        status: Int,
        contentType: String = "text/plain; charset=utf-8",
        extraHeaders: [String: String] = [:],
        body: String
    ) {
        respond(on: conn, status: status, contentType: contentType, extraHeaders: extraHeaders,
                body: Data(body.utf8))
    }

    private func respond(
        on conn: NWConnection,
        status: Int,
        contentType: String = "text/plain; charset=utf-8",
        extraHeaders: [String: String] = [:],
        body: Data
    ) {
        var headerLines = [
            "HTTP/1.1 \(status) \(Self.statusPhrase(status))",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: *"
        ]
        for (k, v) in extraHeaders {
            headerLines.append("\(k): \(v)")
        }
        var response = Data(headerLines.joined(separator: "\r\n").utf8)
        response.append(Data("\r\n\r\n".utf8))
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func respondStreamingHeaders(on conn: NWConnection) {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache, no-transform",
            "Connection: keep-alive",
            "Access-Control-Allow-Origin: *"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        conn.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
    }

    private static func statusPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }

    private static func errorJSON(_ message: String) -> Data {
        let envelope: [String: Any] = [
            "error": [
                "message": message,
                "type": "server_error",
                "code": "internal"
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data()
    }
}
