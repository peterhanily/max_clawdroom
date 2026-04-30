import AppKit
import SwiftUI

/// Renders a `ChatMessageKind.media` entry: a library image inline in
/// the chat bubble, with an optional caption. Handles animated GIFs by
/// bridging to `NSImageView` (SwiftUI's `Image` doesn't animate GIFs
/// natively — it just shows the first frame).
///
/// The wrapper decides between the animated bridge and a plain SwiftUI
/// Image by inspecting the NSImage: if it has multiple frames via
/// NSBitmapImageRep.frameCount, we use the animated path; else static.
struct MediaMessageView: View {
    let libraryName: String
    let caption: String?
    let theme: ChatTheme

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.assistant)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 6) {
                if let ns = ImageLibrary.shared.loadNSImage(named: libraryName) {
                    mediaView(for: ns)
                        .frame(maxWidth: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(theme.assistant.opacity(0.25), lineWidth: 0.5)
                        )
                        // Images render as an empty unlabeled SwiftUI view
                        // to VoiceOver by default — give it a real
                        // announcement so non-sighted users know Max just
                        // posted something.
                        .accessibilityAddTraits(.isImage)
                        .accessibilityLabel(caption?.isEmpty == false
                                            ? "Image: \(caption!)"
                                            : "Image: \(libraryName)")
                } else {
                    // Library entry vanished between post + render;
                    // show a lightweight placeholder instead of crashing
                    // or blanking the message entirely.
                    Text("[image no longer available: \(libraryName)]")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pick animated vs static renderer based on the NSImage's frame
    /// count. GIFs parse as a single NSImage with a multi-frame bitmap
    /// rep; PNG/JPG have a single frame.
    @ViewBuilder
    private func mediaView(for ns: NSImage) -> some View {
        if Self.isAnimated(ns) {
            AnimatedImageView(image: ns)
                .aspectRatio(ns.size, contentMode: .fit)
        } else {
            Image(nsImage: ns)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private static func isAnimated(_ image: NSImage) -> Bool {
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep,
               let frames = bitmap.value(forProperty: .frameCount) as? Int,
               frames > 1 {
                return true
            }
        }
        return false
    }
}

/// NSImageView bridge that animates GIFs. Plain SwiftUI `Image(nsImage:)`
/// renders only the first frame; this wrapper flips `animates = true`
/// so the view controller actually runs the animation loop.
private struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = image
        view.animates = true
        view.canDrawSubviewsIntoLayer = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignTop
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if nsView.image !== image {
            nsView.image = image
            nsView.animates = true
        }
    }
}
