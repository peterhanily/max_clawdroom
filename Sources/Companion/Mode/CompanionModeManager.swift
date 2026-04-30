import AppKit
import Combine
import CoreGraphics

/// Owns Max's current `MaxClawdroomMode`, auto-detects it from display
/// topology, and publishes preset-apply events so the rest of the app
/// (pet scale, jitter, CRT intensity, panel anchor) can react.
///
/// Manual overrides via `setMode(_:userOverride: true)` pin the mode
/// until `resetToAuto()` is called — auto-detection stops fighting the
/// user's choice once they pick one explicitly.
@MainActor
final class MaxClawdroomModeManager: ObservableObject {
    @Published private(set) var mode: MaxClawdroomMode
    @Published private(set) var autoDetected: MaxClawdroomMode
    @Published private(set) var userOverride: MaxClawdroomMode?

    /// Fires every time a preset is applied — new mode, or a re-apply.
    /// Subscribers run `pet.setRootScale`, toggle jitter, update panel
    /// anchor, etc.
    let onApply = PassthroughSubject<ModePreset, Never>()

    private var screenObserver: NSObjectProtocol?

    init() {
        let detected = Self.detectMode()
        self.autoDetected = detected
        self.mode = detected

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.redetect() }
        }
    }

    isolated deinit {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Force a mode. When `userOverride` is true the choice pins auto-detect
    /// out; otherwise it follows the detected value.
    func setMode(_ newMode: MaxClawdroomMode, userOverride: Bool) {
        if userOverride { self.userOverride = newMode }
        mode = newMode
        onApply.send(ModePreset.preset(for: newMode))
    }

    /// Drop manual pin and follow auto-detect again.
    func resetToAuto() {
        userOverride = nil
        setMode(autoDetected, userOverride: false)
    }

    /// Re-run detection on screen-topology change. Only applies if the
    /// user hasn't pinned a specific mode.
    private func redetect() {
        let detected = Self.detectMode()
        autoDetected = detected
        if userOverride == nil {
            setMode(detected, userOverride: false)
        }
    }

    // MARK: - Detection

    static func detectMode() -> MaxClawdroomMode {
        let screens = NSScreen.screens
        guard let main = NSScreen.main else { return .desktop }
        let diagonal = physicalDiagonalInches(screen: main) ?? 0

        // Big external display → TV mode.
        if diagonal > 32 { return .tv }
        // Single small display (built-in laptop panel) → Laptop mode.
        if screens.count == 1 && diagonal > 0 && diagonal <= 16 { return .laptop }
        // Otherwise assume a desktop / multi-monitor workstation.
        return .desktop
    }

    /// Physical diagonal size in inches for the given screen, or nil if
    /// macOS doesn't report the display's physical dimensions (rare —
    /// some virtual displays).
    static func physicalDiagonalInches(screen: NSScreen) -> Double? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let sizeMM = CGDisplayScreenSize(displayID)
        guard sizeMM.width > 0, sizeMM.height > 0 else { return nil }
        let wIn = sizeMM.width / 25.4
        let hIn = sizeMM.height / 25.4
        return (wIn * wIn + hIn * hIn).squareRoot()
    }
}
