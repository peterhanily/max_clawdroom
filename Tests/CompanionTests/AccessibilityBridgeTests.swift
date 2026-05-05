import XCTest
@testable import Companion

/// AX→Cocoa coordinate-conversion tests. The transform only depends on
/// `primaryScreenHeight`, but the contract has to hold across the
/// uncomfortable display geometries macOS users actually run:
///   • single primary
///   • secondary above primary (negative AX y)
///   • secondary below primary (axY > primaryHeight)
///   • tall rectangles wider than the primary screen
///   • zero-size rects (degenerate but legal)
///
/// We pin the pure math via the parameterised overload so the test
/// doesn't touch `NSScreen.screens` (un-mockable in unit tests).
@MainActor
final class AccessibilityBridgeCoordTests: XCTestCase {

    // MARK: - Single-display happy path

    func test_topLeftCornerOfPrimary_mapsToTopOfCocoaSpace() {
        // AX (0,0) is the top-left of primary. A 100×50 rect there
        // occupies AX rows 0..50; in Cocoa that's the top of the
        // screen, so its origin (bottom-left) is at primaryHeight - 50.
        let axRect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let cocoa = AccessibilityBridge.cocoaRect(
            fromAXRect: axRect,
            primaryScreenHeight: 1000
        )
        XCTAssertEqual(cocoa, CGRect(x: 0, y: 950, width: 100, height: 50))
    }

    func test_bottomLeftCornerOfPrimary_mapsToCocoaOrigin() {
        // AX (0, primaryHeight - height) is the rect at the bottom edge
        // of primary; in Cocoa that's at y=0.
        let axRect = CGRect(x: 0, y: 950, width: 100, height: 50)
        let cocoa = AccessibilityBridge.cocoaRect(
            fromAXRect: axRect,
            primaryScreenHeight: 1000
        )
        XCTAssertEqual(cocoa, CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    // MARK: - Display ABOVE primary (negative AX y)

    func test_secondaryAbovePrimary_yieldsCocoaYAbovePrimary() {
        // Secondary display sitting on top of primary: a rect 200px above
        // primary's top edge has AX y = -200 (rect of height 100 starts
        // at AX y = -200, ends at AX y = -100). In Cocoa that's at
        // primaryHeight + 100 (top of primary is primaryHeight; rect
        // bottom is 100px above that).
        let axRect = CGRect(x: 100, y: -200, width: 50, height: 100)
        let cocoa = AccessibilityBridge.cocoaRect(
            fromAXRect: axRect,
            primaryScreenHeight: 1000
        )
        XCTAssertEqual(cocoa.origin.y, 1100,
                       "rect 200px above AX origin should land 100px above Cocoa primary top")
        XCTAssertGreaterThan(cocoa.origin.y, 1000,
                             "must clear primary's top edge (= primaryHeight)")
    }

    // MARK: - Display BELOW primary (axY > primaryHeight)

    func test_secondaryBelowPrimary_yieldsNegativeCocoaY() {
        // Secondary display below primary: a rect at AX y = 1100 with
        // primary height 1000 sits 100px below primary's bottom. In
        // Cocoa primary's bottom is y=0, so the rect's top is at y=-100
        // and its origin (bottom-left) is at y=-100 - height.
        let axRect = CGRect(x: 0, y: 1100, width: 100, height: 50)
        let cocoa = AccessibilityBridge.cocoaRect(
            fromAXRect: axRect,
            primaryScreenHeight: 1000
        )
        XCTAssertEqual(cocoa.origin.y, -150)
        XCTAssertLessThan(cocoa.origin.y, 0,
                          "must be below primary's Cocoa bottom (= 0)")
    }

    // MARK: - Edge cases

    func test_zeroSizeRect_passesThroughWithoutCrash() {
        let axRect = CGRect(x: 42, y: 100, width: 0, height: 0)
        let cocoa = AccessibilityBridge.cocoaRect(
            fromAXRect: axRect,
            primaryScreenHeight: 1000
        )
        XCTAssertEqual(cocoa, CGRect(x: 42, y: 900, width: 0, height: 0))
    }

    func test_rectFillingEntirePrimary_mapsToCocoaOrigin() {
        // Whole-screen rect: AX origin (0,0), size (W,H). Cocoa should
        // be at (0,0,W,H) — the rect IS the primary screen.
        let axRect = CGRect(x: 0, y: 0, width: 1920, height: 1200)
        let cocoa = AccessibilityBridge.cocoaRect(
            fromAXRect: axRect,
            primaryScreenHeight: 1200
        )
        XCTAssertEqual(cocoa, CGRect(x: 0, y: 0, width: 1920, height: 1200))
    }

    func test_xCoordPassesThroughUnchanged() {
        // X axis is shared between AX and Cocoa — no horizontal flip
        // for any of the displays. Pin a few values to catch a future
        // accidental left-right inversion.
        for x in stride(from: -500.0, through: 5000.0, by: 250.0) {
            let cocoa = AccessibilityBridge.cocoaRect(
                fromAXRect: CGRect(x: x, y: 0, width: 1, height: 1),
                primaryScreenHeight: 1000
            )
            XCTAssertEqual(cocoa.origin.x, x, accuracy: 0.001)
        }
    }
}

/// Sensitive-bundle denylist tests. These pin the AX-read gate that
/// PRIVACY.md promises ("password managers, Keychain, terminals,
/// banking, secure messaging — Max gets nil"). Regressions here would
/// silently leak editor context out of those apps into the system
/// prompt + memory + sessions.
@MainActor
final class AccessibilityBridgeDenylistTests: XCTestCase {

    // MARK: - Exact-match denylist

    func test_keychainAccess_isSensitive() {
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("com.apple.keychainaccess"))
    }

    func test_appleMail_isSensitive() {
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("com.apple.mail"))
    }

    func test_signalDesktop_isSensitive() {
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("org.whispersystems.signal-desktop"))
    }

    func test_iterm2_isSensitive() {
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("com.googlecode.iterm2"))
    }

    func test_warp_isSensitive() {
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("dev.warp.Warp-Stable"))
    }

    // MARK: - Prefix-match denylist

    func test_anyOnePasswordVariant_isSensitive() {
        // The 1Password installer + helper apps register variants of
        // `com.1password.<thing>` that aren't all in the explicit set.
        // The prefix-match path covers them.
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("com.1password.installer"))
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("com.1password.helper"))
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("com.1password.future-app"))
    }

    func test_anyKeychainVariant_isSensitive() {
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("com.apple.KeychainCircle"))
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("com.apple.Keychain.helper"))
    }

    func test_anyBitwardenVariant_isSensitive() {
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("com.bitwarden.cli"))
        XCTAssertTrue(AccessibilityBridge.isSensitiveBundle("com.bitwarden.browser-extension-helper"))
    }

    // MARK: - Non-sensitive bundles

    func test_xcode_isNotSensitive() {
        // Editors are explicitly NOT denylisted — the whole product
        // depends on reading editor context. Pin so a future overzealous
        // entry can't accidentally blanket "com.apple."
        XCTAssertFalse(AccessibilityBridge.isSensitiveBundle("com.apple.dt.Xcode"))
    }

    func test_safari_isNotSensitive() {
        XCTAssertFalse(AccessibilityBridge.isSensitiveBundle("com.apple.Safari"))
    }

    func test_vscode_isNotSensitive() {
        XCTAssertFalse(AccessibilityBridge.isSensitiveBundle("com.microsoft.VSCode"))
    }

    func test_finder_isNotSensitive() {
        XCTAssertFalse(AccessibilityBridge.isSensitiveBundle("com.apple.finder"))
    }

    // MARK: - Edge cases

    func test_nilBundle_isNotSensitive() {
        // A nil bundle ID means we couldn't identify the app at all —
        // the original code returned false (let AX read proceed). We
        // keep that posture but flag the call site has to enforce its
        // own gates upstream.
        XCTAssertFalse(AccessibilityBridge.isSensitiveBundle(nil))
    }

    func test_emptyBundle_isNotSensitive() {
        XCTAssertFalse(AccessibilityBridge.isSensitiveBundle(""))
    }

    func test_caseSensitive_caseSwappedKnownEntryDoesNotMatch() {
        // Bundle IDs are case-sensitive in practice (Apple's spec is
        // case-INsensitive but the file system + LSDatabase store the
        // string verbatim). NSWorkspace returns the string as-given.
        // The denylist match is exact / prefix on that string. This
        // pins that posture so a future "be lenient" change has to
        // explicitly opt in.
        XCTAssertFalse(AccessibilityBridge.isSensitiveBundle("COM.APPLE.MAIL"))
    }

    func test_substring_in_middle_does_not_match() {
        // Prefix-match uses `hasPrefix`, NOT contains — confirm a
        // bundle that includes a denylisted substring in the middle
        // is NOT classified as sensitive.
        XCTAssertFalse(AccessibilityBridge.isSensitiveBundle("io.example.com.apple.terminal-clone"))
    }
}
