import SwiftUI

/// Channel-list panel embedded in `SettingsView`. Lists every channel
/// with kind icon, endpoint, active checkmark, and per-row actions
/// (Make Active, Remove). The "Add Channel" button opens
/// `AddChannelWindowController`.
@MainActor
struct ChannelListPanel: View {
    @State private var addController = AddChannelWindowController()
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Channels are the backends Max can attach to — local clawdex on this Mac, a clawdex `--lan` host on the network, or a remote tunnel. Switching channels resets the cached subprocess / socket so the next message routes to the new endpoint.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(ChannelStore.shared.channels) { channel in
                    row(channel)
                    if channel.id != ChannelStore.shared.channels.last?.id {
                        Divider()
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))

            HStack {
                Button {
                    addController.present()
                } label: {
                    Label("Add Channel…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
        .id(refreshTick)
        .onReceive(
            NotificationCenter.default.publisher(for: .companionActiveChannelChanged)
        ) { _ in
            refreshTick += 1
        }
    }

    @ViewBuilder
    private func row(_ channel: Channel) -> some View {
        let isActive = channel.id == ChannelStore.shared.activeID
        HStack(spacing: 10) {
            Image(systemName: kindIcon(channel.kind))
                .frame(width: 18)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(channel.name).font(.system(size: 12, weight: .medium))
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle(channel))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !isActive {
                Button("Make Active") {
                    ChannelStore.shared.setActive(id: channel.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if ChannelStore.shared.channels.count > 1 {
                Button {
                    ChannelStore.shared.remove(id: channel.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove this channel")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    private func kindIcon(_ kind: Channel.Kind) -> String {
        switch kind {
        case .local:         return "laptopcomputer"
        case .lan:           return "wifi"
        case .remote:        return "cloud"
        case .claudeCodeCLI: return "terminal"
        }
    }

    private func subtitle(_ channel: Channel) -> String {
        switch channel.kind {
        case .claudeCodeCLI:
            return "claude CLI · \(channel.cwd ?? "~")"
        case .local, .lan, .remote:
            let m = channel.model.isEmpty ? "" : "  ·  \(channel.model)"
            return "\(channel.endpoint)\(m)"
        }
    }
}
