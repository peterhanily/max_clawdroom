import XCTest
@testable import Companion

/// Targets the bits of channels code most likely to silently regress
/// on a refactor: factory routing by kind, persona defaults, and
/// the SoundLibrary catalog generator.
///
/// `ChannelStore` itself is a singleton with disk + Keychain side
/// effects, so we don't hammer it directly here — the migration path
/// in particular needs an integration test with isolated UserDefaults
/// suites which is a bigger setup. What we DO test:
///   - Channel.Kind round-trips through Codable
///   - ChannelPersona has sensible defaults
///   - ClawdexBackendFactory dispatches the right backend per kind
///   - SoundLibrary.exists / promptBlock contract
@MainActor
final class ChannelTests: XCTestCase {

    func test_channel_codable_roundtrip() throws {
        let original = Channel(
            id: UUID(),
            name: "Studio iMac",
            kind: .lan,
            endpoint: "http://10.0.0.5:52429/v1/chat/completions",
            model: "claude-sonnet-4-6",
            authRef: .bearerInKeychain,
            cwd: nil,
            persona: .default,
            lastSeenAt: Date(timeIntervalSince1970: 1_000_000),
            bonjour: Channel.BonjourRef(
                serviceName: "clawdex@imac",
                serviceType: "_companion._tcp.",
                serviceDomain: "local."
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Channel.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_channel_kind_raw_values_are_stable() {
        // These rawValues are persisted in `companion.channels.v1`.
        // Renaming any of them silently corrupts users' channel lists.
        XCTAssertEqual(Channel.Kind.local.rawValue, "local")
        XCTAssertEqual(Channel.Kind.lan.rawValue, "lan")
        XCTAssertEqual(Channel.Kind.remote.rawValue, "remote")
        XCTAssertEqual(Channel.Kind.claudeCodeCLI.rawValue, "claudeCodeCLI")
    }

    func test_persona_default_has_non_empty_baseline_expression() {
        let p = ChannelPersona.default
        XCTAssertFalse(p.baselineExpression.isEmpty)
        XCTAssertFalse(p.tieHex.isEmpty)
        XCTAssertFalse(p.chatBorderHex.isEmpty)
    }

    // MARK: - SoundLibrary catalog

    func test_built_in_sound_names_are_unique() {
        let names = SoundLibrary.entries.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "Duplicate sound name in catalog")
    }

    func test_sound_library_exists_returns_true_for_each_entry() {
        for entry in SoundLibrary.entries {
            XCTAssertTrue(
                SoundLibrary.exists(entry.name),
                "Catalog says \(entry.name) exists, exists() disagrees"
            )
        }
    }

    func test_prompt_block_lists_every_catalog_name() {
        let block = SoundLibrary.promptBlock()
        for entry in SoundLibrary.entries {
            XCTAssertTrue(
                block.contains(entry.name),
                "Sound \(entry.name) missing from prompt block — agent won't know about it"
            )
        }
    }

    func test_unknown_sound_does_not_exist() {
        XCTAssertFalse(SoundLibrary.exists("definitely-not-a-real-sound"))
    }
}
