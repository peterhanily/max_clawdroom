import XCTest
import CryptoKit
@testable import Companion

/// Unit tests for the raw-byte API on `EncryptedJSONStore` that
/// `MemoryStore` and `ActionAuditLog` rely on for at-rest encryption.
/// The Codable variant has been live for SessionStore + UserModelStore
/// + TimeCapsuleStore for weeks; what's new is the byte-flavoured
/// `sealData` / `openData` / `tolerantLoadData` triple. These tests
/// pin down its behaviour at the boundaries that matter:
///
///   1. Round-trip preservation
///   2. Auth-tag failure on tampered ciphertext (no silent corruption)
///   3. Wrong-key auth failure (separate Keychain installs can't read
///      each other's files)
///   4. Empty-input round-trip (legacy stores write 0-byte files when
///      every entry has been pruned)
///   5. tolerantLoad → encrypted path
///   6. tolerantLoad → legacy plaintext path with the wasPlaintext flag
///   7. tolerantLoad → corrupted-envelope guard (returns nil rather
///      than feeding envelope JSON to the JSONL parser downstream)
@MainActor
final class EncryptedJSONStoreTests: XCTestCase {

    private let key  = SymmetricKey(size: .bits256)
    private let other = SymmetricKey(size: .bits256)

    // MARK: - 1. Round-trip

    func test_sealOpen_roundTrip_preservesBytes() throws {
        let plain = Data("""
        {"kind":"observation","text":"loves espresso"}
        {"kind":"preference","key":"theme","value":"dark"}
        """.utf8)

        let envelope = try EncryptedJSONStore.sealData(plain, using: key)
        XCTAssertNotEqual(envelope, plain, "envelope must not equal plaintext")

        let opened = try EncryptedJSONStore.openData(envelope, using: key)
        XCTAssertEqual(opened, plain)
    }

    // MARK: - 2. Tampered ciphertext

    func test_open_throwsOnTamperedCiphertext() throws {
        let plain = Data("hello world".utf8)
        var envelope = try EncryptedJSONStore.sealData(plain, using: key)

        // Flip a byte well past the JSON header into the ciphertext
        // payload — anywhere in the base64 ciphertext field will do.
        // AES-GCM auth must fail and `open` must throw.
        let mid = envelope.count / 2
        envelope[mid] ^= 0xFF

        XCTAssertThrowsError(
            try EncryptedJSONStore.openData(envelope, using: key),
            "tampered ciphertext must fail GCM auth, not silently decode"
        )
    }

    // MARK: - 3. Wrong key

    func test_open_throwsWithWrongKey() throws {
        let plain = Data("secret".utf8)
        let envelope = try EncryptedJSONStore.sealData(plain, using: key)

        XCTAssertThrowsError(
            try EncryptedJSONStore.openData(envelope, using: other),
            "wrong key must fail — would otherwise mean cross-install reads work"
        )
    }

    // MARK: - 4. Empty input

    func test_sealOpen_emptyInput_roundTrips() throws {
        let plain = Data()
        let envelope = try EncryptedJSONStore.sealData(plain, using: key)
        let opened = try EncryptedJSONStore.openData(envelope, using: key)
        XCTAssertEqual(opened, plain)
    }

    // MARK: - 5. tolerantLoad → encrypted path

    func test_tolerantLoad_decryptsEncrypted() throws {
        let plain = Data("ledger row".utf8)
        let envelope = try EncryptedJSONStore.sealData(plain, using: key)

        let result = EncryptedJSONStore.tolerantLoadData(envelope, using: key)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.value, plain)
        XCTAssertFalse(result?.wasPlaintext ?? true,
                       "envelope path must report wasPlaintext = false")
    }

    // MARK: - 6. tolerantLoad → legacy plaintext

    func test_tolerantLoad_passesLegacyPlaintextThrough() {
        // JSONL bytes from a pre-encryption build. The leading byte is
        // `{` (record start), which is NOT the envelope's `{"v":` prefix
        // because the envelope uses sortedKeys → starts with `{"ciph…`
        // — so the heuristic guard treats this as legacy plaintext.
        let legacy = Data("""
        {"kind":"observation","text":"first entry"}
        {"kind":"observation","text":"second entry"}
        """.utf8)

        let result = EncryptedJSONStore.tolerantLoadData(legacy, using: key)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.value, legacy)
        XCTAssertTrue(result?.wasPlaintext ?? false,
                      "legacy bytes must report wasPlaintext = true so caller migrates")
    }

    // MARK: - 7. tolerantLoad → envelope-we-cannot-open guard

    func test_tolerantLoad_returnsNilForUnopenableEnvelope() throws {
        // Realistic failure: file is a valid envelope (JSON decodes
        // fine, the structural keys are present) but our key can't
        // open it — wrong key from a Keychain reset, or auth-tag bit
        // rot, or a future-version envelope this build doesn't speak.
        // tolerantLoadData must surface nil so the caller refuses
        // rather than feeding envelope JSON to a JSONL parser
        // downstream. Using wrong-key as the cleanest stand-in for the
        // whole "shape OK, contents un-openable" class.
        let plain = Data("payload".utf8)
        let envelope = try EncryptedJSONStore.sealData(plain, using: key)

        let result = EncryptedJSONStore.tolerantLoadData(envelope, using: other)
        XCTAssertNil(result,
                     "envelope-shaped but unopenable must surface as nil")
    }
}
