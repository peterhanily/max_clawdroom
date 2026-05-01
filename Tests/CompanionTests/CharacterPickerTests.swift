import XCTest
@testable import Companion

/// Pin the picker's data contract: the lucky roller draws from the
/// curated pool / the enum cases (no out-of-band values), the BackendSettings
/// migration lands pre-v2 saves on .max with no custom data, and a
/// CustomCharacter round-trips through Codable cleanly.
@MainActor
final class CharacterPickerTests: XCTestCase {

    // MARK: - LuckyRoller

    func test_namePool_is_non_empty_and_curated_size() {
        // The pool is hand-curated. If someone slims it accidentally
        // the lucky button starts repeating immediately — pin a floor
        // without locking the exact number so additions don't fail
        // tests.
        XCTAssertGreaterThanOrEqual(LuckyRoller.namePool.count, 20)
    }

    func test_namePool_has_no_duplicates() {
        let unique = Set(LuckyRoller.namePool)
        XCTAssertEqual(unique.count, LuckyRoller.namePool.count,
                       "Duplicate names dilute the lucky-roll surprise.")
    }

    func test_roll_draws_from_pool_and_enums() {
        // 100 rolls with system RNG — every output must be in the
        // declared pool / enum cases. Catches a future commit that
        // adds an off-pool name in the roller without updating the
        // pool, or vice versa.
        let allOutfits = Set(OutfitPreset.allCases)
        let allThemes = Set(ChatThemePreset.allCases)
        let allNames = Set(LuckyRoller.namePool)
        for _ in 0..<100 {
            let r = LuckyRoller.roll()
            XCTAssertTrue(allNames.contains(r.name), "off-pool name: \(r.name)")
            XCTAssertTrue(allOutfits.contains(r.outfitPreset))
            XCTAssertTrue(allThemes.contains(r.chatThemePreset))
        }
    }

    func test_roll_with_seeded_rng_is_deterministic() {
        // Same seed → same roll, twice in a row. Anchors the contract
        // that `roll(using:)` doesn't reach for entropy beyond the
        // passed-in RNG (e.g. a stray Date() or UUID()).
        var rng1 = SeededRNG(seed: 42)
        var rng2 = SeededRNG(seed: 42)
        let r1 = LuckyRoller.roll(using: &rng1)
        let r2 = LuckyRoller.roll(using: &rng2)
        XCTAssertEqual(r1, r2)
    }

    // MARK: - BackendSettings migration

    func test_pre_v2_decode_lands_on_max_with_no_custom() throws {
        // Hand-rolled JSON missing the new keys — the shape a v0.2.0
        // user has on disk before they update.
        let json = """
        {
          "schemaVersion": 1,
          "claudeBinaryPath": "/usr/local/bin/claude",
          "cwd": "/Users/test",
          "permissionMode": "acceptEdits",
          "allowedTools": "Read,Edit",
          "model": "",
          "systemPrompt": "",
          "companionName": "Max",
          "backendType": "claudeCode",
          "openAIBaseURL": "http://127.0.0.1:52429/v1/chat/completions",
          "openAIApiKey": "",
          "openAIModel": "gpt-4o-mini"
        }
        """
        let decoded = try JSONDecoder().decode(
            BackendSettings.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.characterPreset, .max)
        XCTAssertNil(decoded.customCharacter)
        XCTAssertEqual(decoded.companionName, "Max")
    }

    func test_custom_character_round_trips() throws {
        let original = CustomCharacter(
            name: "Nova",
            outfitPresetId: OutfitPreset.astronaut.rawValue,
            chatThemePresetId: ChatThemePreset.terminal.rawValue
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CustomCharacter.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_v2_settings_round_trip_preserves_custom_character() throws {
        var settings = BackendSettings.default
        settings.characterPreset = .custom
        settings.customCharacter = CustomCharacter(
            name: "Pixel",
            outfitPresetId: OutfitPreset.neon.rawValue,
            chatThemePresetId: ChatThemePreset.comic.rawValue
        )
        settings.companionName = "Pixel"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(BackendSettings.self, from: data)

        XCTAssertEqual(decoded.characterPreset, .custom)
        XCTAssertEqual(decoded.customCharacter?.name, "Pixel")
        XCTAssertEqual(decoded.customCharacter?.outfitPresetId, "neon")
        XCTAssertEqual(decoded.customCharacter?.chatThemePresetId, "comic")
        XCTAssertEqual(decoded.companionName, "Pixel")
    }

    // MARK: - ChatThemePreset

    func test_every_chat_theme_preset_has_a_display_name() {
        // displayName is user-facing — a missing case here would render
        // an empty string in the picker dropdown.
        for preset in ChatThemePreset.allCases {
            XCTAssertFalse(preset.displayName.isEmpty,
                           "missing displayName for \(preset.rawValue)")
        }
    }
}

/// Tiny deterministic RNG so the seeded-roller test isn't at the mercy
/// of `SystemRandomNumberGenerator`. xorshift64* — fine for tests, not
/// fine for security.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }
}
