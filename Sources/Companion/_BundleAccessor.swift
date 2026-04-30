import Foundation

/// Replacement for SwiftPM's auto-generated `Bundle.module`.
///
/// Why not just use `Bundle.module`: SPM's accessor uses
/// `Bundle.main.bundleURL.appendingPathComponent("<name>.bundle")` —
/// for a `.app` wrapper that's the `.app/` root, not Contents/Resources.
/// Putting the bundle there breaks codesigning ("unsealed contents
/// present in the bundle root"); putting it in Contents/Resources/
/// fixes signing but breaks Bundle.module's lookup. This accessor
/// uses `Bundle.main.resourceURL` (= .app/Contents/Resources/) which
/// is the standard macOS resource location, so the bundle ships in
/// the expected place AND is covered by the .app wrapper's seal.
///
/// Usage: replace every `bundle: .module` in this target with
/// `bundle: .companionResources`.
extension Foundation.Bundle {
    static let companionResources: Bundle = {
        // Production path: <.app>/Contents/Resources/max_clawdroom_Companion.bundle
        if let resURL = Bundle.main.resourceURL {
            let bundleURL = resURL.appendingPathComponent("max_clawdroom_Companion.bundle")
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }
        // Dev / SPM-test path: SwiftPM's emitted bundle next to the build
        // product. Keeps `swift test` and `swift run` from a checkout
        // working without packaging.
        let buildName = "max_clawdroom_Companion.bundle"
        let probes: [URL?] = [
            Bundle.main.bundleURL.appendingPathComponent(buildName),
            Bundle(for: BundleProbe.self).bundleURL.deletingLastPathComponent()
                .appendingPathComponent(buildName)
        ]
        for url in probes.compactMap({ $0 }) {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        // Last resort: main bundle. String(localized:bundle:) falls back
        // to the development locale so the app at least renders text.
        return Bundle.main
    }()

    private final class BundleProbe {}
}
