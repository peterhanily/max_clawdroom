import AppKit

/// Occasionally makes Max stare at the cursor and track it with his head.
///
/// Idles for 15–45 s, then locks eyes on the cursor for 3–8 s, updating
/// head direction at 10 Hz, then smoothly returns to neutral and waits
/// again. Paused whenever the user is actively chatting, dragging, or
/// streaming so it never fights other animations.
@MainActor
final class CursorGazeController {
    private weak var pet: Pet?
    /// Returns the pet's current screen-space centre. Evaluated each tick
    /// so it stays correct as Max wanders around.
    private let petCenter: () -> NSPoint

    private var idleTimer: Timer?
    private var gazeTimer: Timer?
    /// One-shot "end gaze after N seconds" timer. Stored so `stop()` can
    /// cancel it — previously this was a fire-and-forget Timer whose
    /// closure kept firing after the user explicitly stopped gazing
    /// (pause / chat open / drag), producing a zombie reschedule.
    private var endGazeTimer: Timer?
    private var isGazing = false
    private var paused = false

    init(pet: Pet, petCenter: @escaping @MainActor () -> NSPoint) {
        self.pet = pet
        self.petCenter = petCenter
    }

    func start() {
        scheduleNext()
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        endGaze(reschedule: false)
    }

    func pause() {
        guard !paused else { return }
        paused = true
        stop()
    }

    func resume() {
        guard paused else { return }
        paused = false
        scheduleNext()
    }

    private func scheduleNext() {
        idleTimer?.invalidate()
        let delay = TimeInterval.random(in: 15...45)
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.startGaze()
        }
    }

    private func startGaze() {
        guard !paused, pet != nil else { return }
        isGazing = true
        let duration = TimeInterval.random(in: 3...8)

        gazeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateGaze()
        }
        endGazeTimer?.invalidate()
        endGazeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.endGaze(reschedule: true)
        }
    }

    private func updateGaze() {
        guard isGazing, let pet else { return }
        let center = petCenter()
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - center.x
        let dy = mouse.y - center.y
        pet.gazeAtOffset(dx: dx, dy: dy)
        pet.setPupilOffset(dx: dx, dy: dy)
    }

    private func endGaze(reschedule: Bool) {
        gazeTimer?.invalidate()
        gazeTimer = nil
        endGazeTimer?.invalidate()
        endGazeTimer = nil
        if isGazing {
            isGazing = false
            pet?.endCursorGaze()
            pet?.resetPupils()
        }
        if reschedule, !paused { scheduleNext() }
    }
}
