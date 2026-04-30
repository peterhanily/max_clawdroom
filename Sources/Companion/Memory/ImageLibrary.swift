import AppKit
import Foundation

/// One curated image the user has added to the library. Images live on
/// disk under `~/Library/Application Support/Companion/images/` and a
/// JSON manifest at the same directory's `manifest.json` records the
/// user-chosen names + source metadata.
///
/// `name` is what the agent references in action ops — cannot contain
/// path separators or shell metacharacters; `ImageLibrary.sanitiseName`
/// normalises user input before save.
struct LibraryImage: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// Display name + agent-facing reference. Unique across the library.
    var name: String
    /// Filename on disk (inside the images dir). Derived from id so a
    /// rename doesn't have to move the file.
    let filename: String
    /// When the user added it.
    let addedAt: Date

    init(id: UUID = UUID(), name: String, filename: String, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.filename = filename
        self.addedAt = addedAt
    }
}

/// User-curated image collection. Images get dropped in via NSOpenPanel
/// from Settings, referenced by short names from agent action ops
/// (`set_part_texture`, `set_chat_background`), and loaded as NSImage
/// when a consumer needs the raw bytes.
///
/// Threat model: the agent gets NO ability to load arbitrary filesystem
/// paths. It can only reference images by name from this library, and
/// the library only holds files the user explicitly added. The library
/// stores the image bytes itself (copied into the images dir on add)
/// so moving / deleting the source file doesn't break references.
@Observable
@MainActor
final class ImageLibrary {

    static let shared = ImageLibrary()

    private(set) var images: [LibraryImage] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let manifestURL: URL

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport
            .appendingPathComponent("Companion", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
        self.manifestURL = dir.appendingPathComponent("manifest.json")
        loadManifest()
    }

    // MARK: - Lookup

    func image(named name: String) -> LibraryImage? {
        let needle = Self.sanitiseName(name)
        return images.first { $0.name.caseInsensitiveCompare(needle) == .orderedSame }
    }

    /// Load the raw NSImage for a named library entry. Nil if the
    /// name is unknown OR the file has vanished under us.
    func loadNSImage(named name: String) -> NSImage? {
        guard let entry = image(named: name) else { return nil }
        let url = directory.appendingPathComponent(entry.filename)
        return NSImage(contentsOf: url)
    }

    /// Compact list of available image names. Fed into the agent's
    /// system prompt so the model knows what it can reference.
    var agentVisibleNames: [String] { images.map(\.name).sorted() }

    // MARK: - Mutations (user-facing)

    /// Import an image from a user-selected URL. Copies the bytes
    /// into the library's directory, records it in the manifest.
    /// Returns the entry on success; nil on I/O failure.
    @discardableResult
    func importImage(from sourceURL: URL, name: String) -> LibraryImage? {
        let cleanName = Self.ensureUnique(Self.sanitiseName(name))
        let id = UUID()
        // Use the id as the filename stem so renames don't touch disk.
        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let filename = "\(id.uuidString).\(ext)"
        let destURL = directory.appendingPathComponent(filename)
        do {
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destURL, options: .atomic)
        } catch {
            AppLog.memory.error("ImageLibrary import failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let entry = LibraryImage(id: id, name: cleanName, filename: filename)
        images.append(entry)
        saveManifest()
        return entry
    }

    func rename(id: UUID, to newName: String) {
        guard let idx = images.firstIndex(where: { $0.id == id }) else { return }
        let sanitised = Self.sanitiseName(newName)
        // Skip rename-to-same + ensure unique if the new name collides
        // with a DIFFERENT entry.
        let existing = images.first { $0.name == sanitised && $0.id != id }
        let final = existing == nil ? sanitised : Self.ensureUnique(sanitised)
        images[idx].name = final
        saveManifest()
    }

    func remove(id: UUID) {
        guard let idx = images.firstIndex(where: { $0.id == id }) else { return }
        let entry = images.remove(at: idx)
        let url = directory.appendingPathComponent(entry.filename)
        try? FileManager.default.removeItem(at: url)
        saveManifest()
    }

    // MARK: - Agent-initiated mutations (gated by Prefs.allowAgentImageOps)

    /// Errors the agent-facing image importers surface. Distinct cases
    /// so the dispatcher can log / display context-specific messages.
    enum ImportError: Error {
        case disabledByUser
        case invalidURL
        case schemeNotAllowed
        case privateAddressBlocked
        case fetchFailed(String)
        case badContentType(String)
        case tooLarge(Int)
        case notAnImage
    }

    /// Max bytes we'll pull for an agent-initiated download. 10 MB is
    /// plenty for any legitimate texture / backdrop; anything larger is
    /// almost certainly the agent pointing at the wrong URL and we
    /// should fail fast.
    static let maxDownloadBytes = 10 * 1024 * 1024
    /// Timeout for the whole request. Keeps a hung endpoint from
    /// parking the agent indefinitely.
    static let downloadTimeout: TimeInterval = 10

    /// Download an image from a URL and add it to the library. Hardened:
    ///   - Pref gate (opt-in)
    ///   - Only http / https
    ///   - Blocks private/loopback/link-local hosts (SSRF defense)
    ///   - Size cap + timeout
    ///   - Content-Type must be image/*
    ///   - First bytes must match a known image magic number
    /// On success, returns the stored LibraryImage. On failure, throws
    /// one of `ImportError`.
    func downloadImage(from urlString: String, name: String) async throws -> LibraryImage {
        guard Prefs.allowAgentImageOps else { throw ImportError.disabledByUser }
        guard let url = URL(string: urlString) else { throw ImportError.invalidURL }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { throw ImportError.schemeNotAllowed }
        guard let host = url.host, !Self.isPrivateOrLoopbackHost(host)
        else { throw ImportError.privateAddressBlocked }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.downloadTimeout
        request.setValue("max_clawdroom/image-fetch", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ImportError.fetchFailed(error.localizedDescription)
        }
        if data.count > Self.maxDownloadBytes { throw ImportError.tooLarge(data.count) }
        if let http = response as? HTTPURLResponse,
           let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !ct.hasPrefix("image/") {
            throw ImportError.badContentType(ct)
        }
        guard let ext = Self.imageExtension(for: data) else { throw ImportError.notAnImage }

        let cleanName = Self.ensureUnique(Self.sanitiseName(name))
        let id = UUID()
        let filename = "\(id.uuidString).\(ext)"
        let destURL = directory.appendingPathComponent(filename)
        do {
            try data.write(to: destURL, options: .atomic)
        } catch {
            throw ImportError.fetchFailed(error.localizedDescription)
        }
        let entry = LibraryImage(id: id, name: cleanName, filename: filename)
        images.append(entry)
        saveManifest()
        return entry
    }

    /// Render a procedural pattern as an NSImage and add it to the
    /// library. Lets the agent "generate" simple tileable textures
    /// (noise, solid, gradient, checker) without touching the network.
    /// The pattern is rendered in-process via Core Graphics.
    func createPatternImage(
        kind: String,
        primaryHex: String,
        accentHex: String?,
        size: CGFloat = 256,
        name: String
    ) throws -> LibraryImage {
        guard Prefs.allowAgentImageOps else { throw ImportError.disabledByUser }
        guard let primary = NSColor.fromHex(primaryHex) else { throw ImportError.invalidURL }
        let accent = accentHex.flatMap(NSColor.fromHex) ?? primary.blended(withFraction: 0.4, of: .black) ?? primary
        let side = max(64, min(1024, size))
        let image = Self.renderPattern(kind: kind.lowercased(), primary: primary, accent: accent, side: side)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ImportError.notAnImage }

        let cleanName = Self.ensureUnique(Self.sanitiseName(name))
        let id = UUID()
        let filename = "\(id.uuidString).png"
        let destURL = directory.appendingPathComponent(filename)
        do {
            try png.write(to: destURL, options: .atomic)
        } catch {
            throw ImportError.fetchFailed(error.localizedDescription)
        }
        let entry = LibraryImage(id: id, name: cleanName, filename: filename)
        images.append(entry)
        saveManifest()
        return entry
    }

    // MARK: - Tour seed

    /// Names the tour expects to find. The tour calls `ensureTourSeeds()`
    /// before running so a fresh user with an empty library still gets
    /// the image / background / texture beats. Names are stable and
    /// readable so users see them in Settings → Images after the tour
    /// and can play with them.
    enum TourAsset: String, CaseIterable {
        case stripes  = "tour-stripes"   // suit texture demo
        case gradient = "tour-gradient"  // chat background demo
        case checker  = "tour-checker"   // inline chat image demo
    }

    /// Idempotent: any tour asset already present (by name) is left
    /// alone, missing ones are rendered + persisted. Bypasses the
    /// `allowAgentImageOps` pref because the user explicitly started
    /// the tour and these are reserved demo names — no agent input
    /// path reaches here.
    func ensureTourSeeds() {
        for asset in TourAsset.allCases where image(named: asset.rawValue) == nil {
            seedTourAsset(asset)
        }
    }

    private func seedTourAsset(_ asset: TourAsset) {
        let (kind, primary, accent): (String, NSColor, NSColor) = {
            switch asset {
            case .stripes:
                return ("stripes",
                        NSColor(srgbRed: 1.000, green: 0.176, blue: 0.541, alpha: 1.0),
                        NSColor(srgbRed: 0.176, green: 0.882, blue: 0.988, alpha: 1.0))
            case .gradient:
                return ("gradient",
                        NSColor(srgbRed: 0.082, green: 0.020, blue: 0.231, alpha: 1.0),
                        NSColor(srgbRed: 1.000, green: 0.176, blue: 0.541, alpha: 1.0))
            case .checker:
                return ("checker",
                        NSColor(srgbRed: 0.969, green: 0.816, blue: 0.275, alpha: 1.0),
                        NSColor(srgbRed: 0.082, green: 0.020, blue: 0.231, alpha: 1.0))
            }
        }()
        let nsImage = Self.renderPattern(kind: kind, primary: primary, accent: accent, side: 256)
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        let id = UUID()
        let filename = "\(id.uuidString).png"
        let destURL = directory.appendingPathComponent(filename)
        do {
            try png.write(to: destURL, options: .atomic)
        } catch {
            AppLog.memory.error("tour seed write failed for \(asset.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let entry = LibraryImage(id: id, name: asset.rawValue, filename: filename)
        images.append(entry)
        saveManifest()
    }

    // MARK: - URL / content helpers

    /// Block hosts that would let a rogue agent probe the local network
    /// via image-download side channels. Covers IPv4 private ranges,
    /// IPv6 loopback/link-local, and the most obvious hostname variants.
    /// Not a complete SSRF defense (can't resolve + re-check without a
    /// lot more plumbing) but covers the common cases.
    nonisolated private static func isPrivateOrLoopbackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "ip6-localhost" || lower == "::1" {
            return true
        }
        // Literal IPv4.
        let parts = lower.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            let a = parts[0], b = parts[1]
            // RFC 1918 + loopback + link-local + CGNAT.
            if a == 10 { return true }
            if a == 127 { return true }
            if a == 169 && b == 254 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 192 && b == 168 { return true }
            if a == 100 && (64...127).contains(b) { return true }
            if a == 0 { return true }
        }
        // IPv6 literal shortcuts.
        if lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") {
            return true
        }
        // `.local` mDNS names shouldn't be reachable for image fetches.
        if lower.hasSuffix(".local") { return true }
        return false
    }

    /// Magic-number sniffer. Returns the file extension if the blob is
    /// a recognised image format; nil otherwise.
    nonisolated private static func imageExtension(for data: Data) -> String? {
        guard data.count >= 8 else { return nil }
        let b = [UInt8](data.prefix(12))
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        // JPEG: FF D8 FF
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        // GIF: GIF87a / GIF89a
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        // WebP: RIFF ???? WEBP
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        // HEIC / HEIF: ftyp heic / heif
        if b.count >= 12, b[4...7] == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(data: data.subdata(in: 8..<12), encoding: .ascii)?.lowercased() ?? ""
            if brand.hasPrefix("heic") || brand.hasPrefix("heif") || brand.hasPrefix("mif1") {
                return "heic"
            }
        }
        // TIFF: II 2A 00 or MM 00 2A
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "tiff"
        }
        return nil
    }

    /// Render a procedural pattern to an NSImage. Simple but enough
    /// variety to be useful — solid / noise / checker / gradient /
    /// stripes. All tileable.
    nonisolated private static func renderPattern(
        kind: String, primary: NSColor, accent: NSColor, side: CGFloat
    ) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        let rect = CGRect(origin: .zero, size: size)
        switch kind {
        case "solid":
            ctx.setFillColor(primary.cgColor)
            ctx.fill(rect)
        case "noise":
            // White base + per-pixel stochastic dots of the accent so the
            // output tiles without seams at small sizes.
            ctx.setFillColor(primary.cgColor)
            ctx.fill(rect)
            ctx.setFillColor(accent.cgColor)
            let density = 0.12
            var rng = SystemRandomNumberGenerator()
            for y in stride(from: 0, to: Int(side), by: 2) {
                for x in stride(from: 0, to: Int(side), by: 2) {
                    if Double.random(in: 0...1, using: &rng) < density {
                        ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
                    }
                }
            }
        case "checker":
            let tile = max(8, side / 8)
            ctx.setFillColor(primary.cgColor)
            ctx.fill(rect)
            ctx.setFillColor(accent.cgColor)
            var y: CGFloat = 0
            var row = 0
            while y < side {
                var x: CGFloat = (row % 2 == 0) ? 0 : tile
                while x < side {
                    ctx.fill(CGRect(x: x, y: y, width: tile, height: tile))
                    x += tile * 2
                }
                y += tile
                row += 1
            }
        case "stripes":
            ctx.setFillColor(primary.cgColor)
            ctx.fill(rect)
            ctx.setFillColor(accent.cgColor)
            let stride = max(8, side / 10)
            var x: CGFloat = 0
            while x < side {
                ctx.fill(CGRect(x: x, y: 0, width: stride, height: side))
                x += stride * 2
            }
        case "gradient":
            let colors = [primary.cgColor, accent.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: side, y: side),
                                       options: [])
            } else {
                ctx.setFillColor(primary.cgColor)
                ctx.fill(rect)
            }
        default:
            ctx.setFillColor(primary.cgColor)
            ctx.fill(rect)
        }
        image.unlockFocus()
        return image
    }

    // MARK: - Sanitisation

    /// Normalise a user-typed name into something safe to reference.
    /// Rules: strip control chars + path separators + quotes + brackets,
    /// collapse whitespace, cap at 40 chars, fallback to "image".
    static func sanitiseName(_ input: String) -> String {
        let disallowed: Set<Character> = [
            "/", "\\", ":", "[", "]", "{", "}",
            "<", ">", "\"", "'", "`", ";",
            "\n", "\r", "\t"
        ]
        var cleaned = ""
        for ch in input where !disallowed.contains(ch) {
            // Also skip ASCII controls.
            let ok = ch.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
            if ok { cleaned.append(ch) }
        }
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        let capped = trimmed.count > 40 ? String(trimmed.prefix(40)) : trimmed
        return capped.isEmpty ? "image" : capped
    }

    private static func ensureUnique(_ base: String) -> String {
        // If no collision, return as-is. Else append " 2", " 3", …
        let existing = Set(ImageLibrary.shared.images.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Persistence

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([LibraryImage].self, from: data) {
            images = list
        }
    }

    private func saveManifest() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(images) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}
