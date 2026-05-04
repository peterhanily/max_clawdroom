import CryptoKit
import Foundation

/// At-rest encryption helper for small JSON-backed stores whose
/// contents shouldn't be readable by other processes running as the
/// same user — soul prompts, user models, time capsules. Wraps
/// AES-GCM (CryptoKit.AES.GCM) around Codable values.
///
/// On-disk format is a versioned envelope so future migrations can
/// evolve cipher / tag shape without breaking existing files:
///
///     {
///       "v": 1,
///       "nonce": "<base64 12B>",
///       "ciphertext": "<base64>",
///       "tag": "<base64 16B>"
///     }
///
/// The `tolerantLoad` entry point auto-detects the legacy plaintext
/// format (decodes as T directly) and flags the caller to re-save in
/// encrypted form — one-shot migration with no user action needed.
enum EncryptedJSONStore {

    /// Versioned on-disk envelope. v1 is AES-GCM with a 12-byte nonce
    /// and 16-byte tag; both stored base64 alongside the ciphertext.
    private struct Envelope: Codable {
        let v: Int
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    /// Current envelope version. Bump when the cipher or format
    /// changes; existing files stay readable via dispatch on `v`.
    private static let currentVersion = 1

    // MARK: - Encode

    /// Seal `value` into an envelope `Data` ready to write to disk.
    /// Throws if encoding or encryption fails.
    static func encode<T: Encodable>(
        _ value: T,
        using key: SymmetricKey
    ) throws -> Data {
        let plain = try JSONEncoder.shared.encode(value)
        let sealed = try AES.GCM.seal(plain, using: key)
        // `sealed.nonce` is 12 bytes (CryptoKit enforces); `sealed.tag`
        // is 16 bytes. Both stored verbatim so decryption can
        // reconstruct the `SealedBox` without guesswork.
        let envelope = Envelope(
            v: currentVersion,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
        return try JSONEncoder.shared.encode(envelope)
    }

    // MARK: - Decode

    /// Unseal an envelope `Data` back into `T`. Throws on version
    /// mismatch, malformed envelope, or auth-tag failure.
    static func decode<T: Decodable>(
        _ data: Data,
        as type: T.Type,
        using key: SymmetricKey
    ) throws -> T {
        let envelope = try JSONDecoder.shared.decode(Envelope.self, from: data)
        guard envelope.v == currentVersion else {
            throw EncryptedStoreError.unsupportedVersion(envelope.v)
        }
        let nonce = try AES.GCM.Nonce(data: envelope.nonce)
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        let plain = try AES.GCM.open(box, using: key)
        return try JSONDecoder.shared.decode(T.self, from: plain)
    }

    // MARK: - Migration-aware load

    /// Result of a tolerant load — the value + whether the source was
    /// legacy plaintext (so the caller knows to re-save in encrypted
    /// form on the next write).
    struct LoadResult<T> {
        let value: T
        let wasPlaintext: Bool
    }

    /// Try decrypt first; on failure, try decoding the blob as raw `T`
    /// (legacy plaintext format). Returns nil if both paths fail.
    ///
    /// Doesn't modify `data` — the caller owns the re-save decision.
    /// On a plaintext-migration hit, flag `wasPlaintext = true` so the
    /// caller can immediately re-save through the encrypted path and
    /// wipe the legacy blob.
    static func tolerantLoad<T: Decodable>(
        _ data: Data,
        as type: T.Type,
        using key: SymmetricKey
    ) -> LoadResult<T>? {
        if let decrypted = try? decode(data, as: type, using: key) {
            return LoadResult(value: decrypted, wasPlaintext: false)
        }
        if let plaintext = try? JSONDecoder.shared.decode(type, from: data) {
            return LoadResult(value: plaintext, wasPlaintext: true)
        }
        return nil
    }

    // MARK: - Raw byte API (for line-oriented stores)

    /// Seal arbitrary bytes into the same envelope format. Used by
    /// stores whose on-disk representation isn't a single Codable value
    /// — e.g. JSONL ledgers (memory, action audit log) where the
    /// natural unit is line-separated bytes, not one struct.
    ///
    /// The envelope shape is identical to the Codable variant above, so
    /// the version byte and decryption path stay shared.
    static func sealData(
        _ plain: Data,
        using key: SymmetricKey
    ) throws -> Data {
        let sealed = try AES.GCM.seal(plain, using: key)
        let envelope = Envelope(
            v: currentVersion,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
        return try JSONEncoder.shared.encode(envelope)
    }

    /// Open a sealed-bytes envelope. Symmetrical with `sealData`.
    /// Throws on version mismatch, malformed envelope, or auth-tag
    /// failure (latter is the canary for a tampered file).
    static func openData(
        _ envelopeData: Data,
        using key: SymmetricKey
    ) throws -> Data {
        let envelope = try JSONDecoder.shared.decode(Envelope.self, from: envelopeData)
        guard envelope.v == currentVersion else {
            throw EncryptedStoreError.unsupportedVersion(envelope.v)
        }
        let nonce = try AES.GCM.Nonce(data: envelope.nonce)
        let box = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: envelope.ciphertext,
            tag: envelope.tag
        )
        return try AES.GCM.open(box, using: key)
    }

    /// Tolerantly load file contents as raw bytes. Tries the encrypted
    /// envelope first; if decoding/decrypting fails, returns the input
    /// as-is and flags `wasPlaintext = true`. Callers use that flag to
    /// trigger a migrate-on-next-write — same shape as the Codable
    /// `tolerantLoad`. Returns nil only if both forms fail (which for
    /// the byte-level API means the envelope failed AND the input is
    /// empty / unreadable; arbitrary bytes are always a "valid"
    /// plaintext).
    static func tolerantLoadData(
        _ blob: Data,
        using key: SymmetricKey
    ) -> LoadResult<Data>? {
        if let plain = try? openData(blob, using: key) {
            return LoadResult(value: plain, wasPlaintext: false)
        }
        // openData failed. Discriminate "envelope-shaped but
        // un-openable" (corruption / wrong key / version skew) from
        // "not an envelope at all" (legacy plaintext) by attempting
        // just the structural decode. Legacy JSONL has no `nonce` /
        // `ciphertext` / `tag` keys so the Envelope decode will fail
        // and we route to plaintext. A tampered envelope still decodes
        // structurally (the JSON shell is intact) but couldn't be
        // opened — those we surface as nil so the caller refuses
        // rather than feeding envelope JSON to a JSONL parser.
        if (try? JSONDecoder.shared.decode(Envelope.self, from: blob)) != nil {
            return nil
        }
        return LoadResult(value: blob, wasPlaintext: true)
    }
}

// MARK: - Errors

enum EncryptedStoreError: Error, LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "EncryptedJSONStore: unsupported envelope version \(v)"
        }
    }
}

// MARK: - Shared codec instances

/// Sharing the encoders avoids per-call instantiation cost and keeps
/// the date strategy consistent across call sites.
private extension JSONEncoder {
    static let shared: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let shared: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
