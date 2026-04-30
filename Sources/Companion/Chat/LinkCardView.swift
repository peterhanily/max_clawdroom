import AppKit
import SwiftUI

/// Rich link preview. Agent posts via `post_link` with a URL + title +
/// optional description + optional thumbnail (library image name).
/// Click → opens in the default browser. No network fetches happen
/// here — the agent supplies the metadata it already knows OR runs
/// `download_image` first to stash a thumbnail.
///
/// Design: matches the assistant bubble chrome (▸ glyph, monospace,
/// theme-coloured stroke). Thumbnail left, title + description +
/// hostname right. Tapping anywhere on the card opens the URL.
struct LinkCardView: View {
    let urlString: String
    let title: String
    let description: String?
    let thumbnailLibraryName: String?
    let theme: ChatTheme

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.assistant)
                .padding(.top, 3)

            Button(action: open) {
                HStack(alignment: .center, spacing: 10) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let description, !description.isEmpty {
                            Text(description)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.text.opacity(0.75))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Text(hostname)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.assistant.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.assistant.opacity(0.35), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 420)
            // Collapse the card into one element VoiceOver reads as a
            // single "Link: Title, hostname, opens in browser" phrase
            // rather than reading title / description / hostname as
            // three orphan labels after the button itself.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isLink)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityHint("Opens \(hostname) in your default browser")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            }
            Button("Open in Browser") { open() }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let name = thumbnailLibraryName,
           let ns = ImageLibrary.shared.loadNSImage(named: name) {
            Image(nsImage: ns)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            // Fallback glyph keyed to the host — recognisable monochrome
            // SF symbol per host family. Cheap, avoids fetching the real
            // favicon (which would need network + cache).
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.assistant.opacity(0.12))
                .overlay(
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(theme.assistant.opacity(0.7))
                )
                .frame(width: 64, height: 64)
        }
    }

    private var hostname: String {
        URL(string: urlString)?.host ?? urlString
    }

    private var accessibilityDescription: String {
        var parts = ["Link: \(title)"]
        if let description, !description.isEmpty {
            parts.append(description)
        }
        parts.append("from \(hostname)")
        return parts.joined(separator: ", ")
    }

    /// Simple per-host glyph mapping. Adds zero network cost; covers
    /// the common places Max is likely to link to.
    private var fallbackSymbol: String {
        let host = hostname.lowercased()
        if host.contains("youtube") || host.contains("youtu.be") || host.contains("vimeo") {
            return "play.rectangle.fill"
        }
        if host.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if host.contains("twitter") || host.contains("x.com") { return "bubble.left.fill" }
        if host.contains("news") || host.contains("nyt") || host.contains("bbc") {
            return "newspaper.fill"
        }
        if host.contains("music") || host.contains("spotify") || host.contains("bandcamp") {
            return "music.note"
        }
        return "link"
    }

    private func open() {
        // Mirror the http/https allowlist from the post_link action
        // dispatcher. Belt-and-suspenders: the action side already
        // rejects non-http(s) schemes, but never hand NSWorkspace a URL
        // we didn't re-check at the point of use. A prompt-injected
        // `file://`, `x-apple-*://` or custom scheme stops here.
        guard
            let url = URL(string: urlString),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return }
        NSWorkspace.shared.open(url)
    }
}
