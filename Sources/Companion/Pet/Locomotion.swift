import AppKit
import SceneKit

/// Minimal wandering AI. Picks a random x within screen bounds, walks there,
/// pauses, repeats. Real pathfinding with window awareness comes later.
final class Locomotion {
    weak var pet: Pet?
    let bounds: NSRect
    private var timer: Timer?
    private var paused = false

    init(pet: Pet, bounds: NSRect) {
        self.pet = pet
        self.bounds = bounds
    }

    func start() {
        scheduleNext(after: 3.0)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func pauseFor(duration: TimeInterval) {
        paused = true
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.paused = false
            self?.scheduleNext(after: 0.8)
        }
    }

    func pause() {
        paused = true
        stop()
    }

    func resume() {
        guard paused else { return }
        paused = false
        scheduleNext(after: 1.2)
    }

    private func scheduleNext(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.step()
        }
    }

    private func step() {
        guard !paused, let pet = pet else { return }
        let eagerness = max(0.1, pet.form.walkEagerness)
        let idlePause = TimeInterval.random(in: 6.0...18.0) / eagerness

        // Idle variation — occasionally turn to look around instead of walk.
        // Keeps him from feeling like a one-trick pony with only the walk
        // animation available.
        if Int.random(in: 0..<10) < 3 {
            pet.lookAround()
            scheduleNext(after: idlePause * 0.6)
            return
        }

        let padding: CGFloat = 120
        let minStep: CGFloat = 180
        let maxStep: CGFloat = 420
        let current = pet.node.presentation.position
        let currentX = CGFloat(current.x)
        let currentY = CGFloat(current.y)
        let stepDistance = CGFloat.random(in: minStep...maxStep)
        let direction: CGFloat = Bool.random() ? 1 : -1
        var targetX = currentX + direction * stepDistance
        targetX = max(padding, min(bounds.width - padding, targetX))
        // Gravity off — walk horizontally at the current Y, don't force baseY.
        let targetY = Prefs.gravityEnabled ? pet.form.baseY : currentY
        let dx = abs(currentX - targetX)
        let dy = abs(currentY - targetY)
        let totalDistance = hypot(dx, dy)
        if totalDistance < 40 {
            scheduleNext(after: idlePause)
            return
        }
        let speed: CGFloat = 55
        let duration = max(1.2, Double(totalDistance / speed))
        pet.face(right: targetX > currentX)
        pet.moveTo(x: targetX, y: targetY, duration: duration)
        scheduleNext(after: duration + idlePause)
    }
}
