import AppKit
import Foundation
import Network
import SwiftUI

/// Sheet for creating a new channel. Three tabs map onto the three
/// transport tiers: Local (loopback), LAN (Bonjour + 6-digit pair),
/// Remote (paste a URL + bearer for Tailscale / Cloudflare Tunnel /
/// direct port-forward). On success it adds the channel and activates
/// it via `ChannelStore`.
@MainActor
struct AddChannelView: View {
    enum Tier: String, CaseIterable, Identifiable {
        case local, lan, remote
        var id: String { rawValue }
        var label: String {
            switch self {
            case .local:  return "Local"
            case .lan:    return "LAN"
            case .remote: return "Remote"
            }
        }
    }

    var onClose: () -> Void

    @State private var tier: Tier = .local

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add Channel")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            Picker("", selection: $tier) {
                ForEach(Tier.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            switch tier {
            case .local:  LocalTab(onAdded: onClose)
            case .lan:    LANTab(onAdded: onClose)
            case .remote: RemoteTab(onAdded: onClose)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }
}

// MARK: - Local

private struct LocalTab: View {
    var onAdded: () -> Void
    @State private var name = "This Mac"
    @State private var endpoint = Constants.Clawdex.chatCompletionsURL
    @State private var model = "claude-sonnet-4-6"
    @State private var test: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to a clawdex running on this Mac (loopback). No auth needed — the endpoint isn't reachable from outside this machine.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            field("Name") {
                TextField("This Mac", text: $name).textFieldStyle(.roundedBorder)
            }
            field("Endpoint") {
                TextField(Constants.Clawdex.chatCompletionsURL, text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            field("Model") {
                TextField("claude-sonnet-4-6", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            HStack(spacing: 10) {
                Button("Test") { runTest() }
                    .buttonStyle(.bordered)
                    .disabled(test == .testing || endpoint.isEmpty)
                test.label
                Spacer()
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || endpoint.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func runTest() {
        guard let url = modelsURL(from: endpoint) else {
            test = .fail("Bad endpoint URL"); return
        }
        test = .testing
        Task {
            let result = await probe(url: url, bearer: nil)
            await MainActor.run { test = result }
        }
    }

    private func add() {
        let ch = Channel(
            name: name,
            kind: .local,
            endpoint: endpoint,
            model: model,
            authRef: .none
        )
        ChannelStore.shared.add(ch)
        ChannelStore.shared.setActive(id: ch.id)
        onAdded()
    }
}

// MARK: - LAN

private struct LANTab: View {
    var onAdded: () -> Void
    @State private var browser = ClawdexBrowser()
    @State private var selected: DiscoveredClawdex?
    @State private var pairingCode: String = ""
    @State private var deviceName: String = Host.current().localizedName ?? "Mac"
    @State private var name: String = ""
    @State private var model: String = "claude-sonnet-4-6"
    @State private var status: PairStatus = .idle

    enum PairStatus: Equatable {
        case idle, pairing, ok, failed(String)
        @ViewBuilder var label: some View {
            switch self {
            case .idle:        EmptyView()
            case .pairing:     ProgressView().controlSize(.small)
            case .ok:          Text("Paired").foregroundStyle(.green).font(.system(size: 11))
            case .failed(let m): Text(m).foregroundStyle(.red).font(.system(size: 11))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            blurb
            hostsList
            fields
            actions
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private var blurb: some View {
        Text("Pair with a clawdex `--lan` instance on the LAN. Run `clawdex --lan` on the host Mac, then enter the 6-digit code shown in its terminal banner.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var hostsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Discovered hosts").font(.system(size: 11, weight: .medium))
            if browser.hosts.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching for clawdex on the LAN…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(browser.hosts) { host in
                        hostRow(host)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private func hostRow(_ host: DiscoveredClawdex) -> some View {
        let isSelected = selected?.id == host.id
        return HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(host.displayName).font(.system(size: 12))
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            selected = host
            if name.isEmpty { name = host.displayName }
        }
    }

    @ViewBuilder
    private var fields: some View {
        field("Pairing code") {
            TextField("123456", text: $pairingCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 110)
        }
        field("Device name") {
            TextField("Mac", text: $deviceName).textFieldStyle(.roundedBorder)
        }
        field("Channel name") {
            TextField("Studio iMac", text: $name).textFieldStyle(.roundedBorder)
        }
        field("Model") {
            TextField("claude-sonnet-4-6", text: $model)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Pair & Add") { pair() }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil || pairingCode.count < 4 || name.isEmpty || status == .pairing)
                .keyboardShortcut(.defaultAction)
            status.label
            Spacer()
        }
    }

    private func pair() {
        guard let host = selected else { return }
        status = .pairing
        Task {
            do {
                let resolved = try await ClawdexPairing.resolve(endpoint: host.endpoint)
                let result = try await ClawdexPairing.pair(
                    host: resolved.host,
                    port: resolved.port,
                    pairingCode: pairingCode,
                    deviceName: deviceName
                )
                await MainActor.run {
                    let id = UUID()
                    let endpoint = "http://\(resolved.host):\(resolved.port)/v1/chat/completions"
                    let bonjour = Channel.BonjourRef(
                        serviceName: host.displayName,
                        serviceType: "_companion._tcp.",
                        serviceDomain: "local."
                    )
                    let ch = Channel(
                        id: id,
                        name: name,
                        kind: .lan,
                        endpoint: endpoint,
                        model: model,
                        authRef: .bearerInKeychain,
                        bonjour: bonjour
                    )
                    KeychainStore.write(
                        account: KeychainStore.bearerAccount(for: id),
                        value: result.token
                    )
                    ChannelStore.shared.add(ch)
                    ChannelStore.shared.setActive(id: id)
                    status = .ok
                    onAdded()
                }
            } catch {
                let msg = (error as? ClawdexPairing.PairError)?.errorDescription
                    ?? error.localizedDescription
                await MainActor.run { status = .failed(msg) }
            }
        }
    }
}

// MARK: - Remote

private struct RemoteTab: View {
    enum Preset: String, CaseIterable, Identifiable {
        case tailscale, cloudflare, direct
        var id: String { rawValue }
        var label: String {
            switch self {
            case .tailscale:  return "Tailscale"
            case .cloudflare: return "Cloudflare Tunnel"
            case .direct:     return "Direct"
            }
        }
        var defaultName: String {
            switch self {
            case .tailscale:  return "Tailnet Max"
            case .cloudflare: return "Cloud Max"
            case .direct:     return "Remote Max"
            }
        }
        var endpointPlaceholder: String {
            switch self {
            case .tailscale:  return "https://<MagicDNS-name>:52429/v1/chat/completions"
            case .cloudflare: return "https://clawdex-<id>.trycloudflare.com/v1/chat/completions"
            case .direct:     return "https://your-host:52429/v1/chat/completions"
            }
        }
        var howTo: String {
            switch self {
            case .tailscale:
                return "On the host Mac: install Tailscale, then run `clawdex --api-key <secret> -H 0.0.0.0`. Use the host's MagicDNS name (Tailscale menu bar → Copy IP / hostname). The bearer is the `--api-key` value."
            case .cloudflare:
                return "On the host Mac: run `cloudflared tunnel --url http://localhost:52429` for an ad-hoc URL, or set up a named tunnel for stability. Use the printed `https://...trycloudflare.com` URL plus your `clawdex --api-key`."
            case .direct:
                return "Open a port on the host's router (or run on a machine with a public IP), and start `clawdex --api-key <secret> -H 0.0.0.0`. Only do this on a network you trust."
            }
        }
    }

    var onAdded: () -> Void
    @State private var preset: Preset = .tailscale
    @State private var name = ""
    @State private var endpoint = ""
    @State private var bearer = ""
    @State private var model = "claude-sonnet-4-6"
    @State private var test: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to a clawdex over the internet. Pick a preset for the recipe, fill in the URL and the `--api-key` bearer.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $preset) {
                ForEach(Preset.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: preset) { _, new in
                if name.isEmpty { name = new.defaultName }
            }

            Text(preset.howTo)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))

            field("Name") {
                TextField(preset.defaultName, text: $name).textFieldStyle(.roundedBorder)
            }
            field("Endpoint") {
                TextField(preset.endpointPlaceholder, text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            field("Bearer") {
                SecureField("Token (clawdex --api-key)", text: $bearer)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            field("Model") {
                TextField("claude-sonnet-4-6", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

            HStack(spacing: 10) {
                Button("Test") { runTest() }
                    .buttonStyle(.bordered)
                    .disabled(test == .testing || endpoint.isEmpty)
                test.label
                Spacer()
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || endpoint.isEmpty || bearer.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func runTest() {
        guard let url = modelsURL(from: endpoint) else {
            test = .fail("Bad endpoint URL"); return
        }
        test = .testing
        Task {
            let result = await probe(url: url, bearer: bearer.isEmpty ? nil : bearer)
            await MainActor.run { test = result }
        }
    }

    private func add() {
        let id = UUID()
        let hasBearer = !bearer.isEmpty
        if hasBearer {
            KeychainStore.write(account: KeychainStore.bearerAccount(for: id), value: bearer)
        }
        let ch = Channel(
            id: id,
            name: name,
            kind: .remote,
            endpoint: endpoint,
            model: model,
            authRef: hasBearer ? .bearerInKeychain : .none
        )
        ChannelStore.shared.add(ch)
        ChannelStore.shared.setActive(id: id)
        onAdded()
    }
}

// MARK: - Shared bits

private enum TestState: Equatable {
    case idle, testing, ok(String), fail(String)
    @ViewBuilder var label: some View {
        switch self {
        case .idle:           EmptyView()
        case .testing:        ProgressView().controlSize(.small)
        case .ok(let v):      Text(v).foregroundStyle(.green).font(.system(size: 11))
        case .fail(let m):    Text(m).foregroundStyle(.red).font(.system(size: 11))
        }
    }
}

@MainActor
@ViewBuilder
private func field<Content: View>(
    _ label: String,
    @ViewBuilder content: () -> Content
) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(label)
            .font(.system(size: 12))
            .frame(width: 96, alignment: .trailing)
        content()
    }
}

/// Derive `<base>/v1/models` from a `/v1/chat/completions` URL. Used by
/// the Test buttons to do a cheap reachability check.
private func modelsURL(from chatCompletionsURL: String) -> URL? {
    guard var components = URLComponents(string: chatCompletionsURL) else { return nil }
    var path = components.path
    if path.hasSuffix("/chat/completions") {
        path = String(path.dropLast("/chat/completions".count)) + "/models"
    } else if path.hasSuffix("/") {
        path += "models"
    } else {
        path += "/models"
    }
    components.path = path
    return components.url
}

/// Cheap reachability + auth check. 1.5s timeout — anything slower means
/// the user is going to feel pain on every send anyway.
private func probe(url: URL, bearer: String?) async -> TestState {
    var req = URLRequest(url: url)
    req.timeoutInterval = 1.5
    if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    do {
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            return .fail("non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300: return .ok("Reachable")
        case 401:       return .fail("Unauthorized — check bearer")
        case 404:       return .fail("404 — endpoint URL doesn't expose /models")
        default:        return .fail("HTTP \(http.statusCode)")
        }
    } catch {
        return .fail(error.localizedDescription)
    }
}
