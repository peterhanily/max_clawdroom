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
