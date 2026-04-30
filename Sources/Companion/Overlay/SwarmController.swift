import AppKit
import Combine
import SceneKit

/// Renders the sub-agent creature swarm. When Claude Code dispatches a Task
/// sub-agent, a small OrbForm pet spawns, scurries to a corner slot, pulses
/// while the sub-agent is working, and animates back into the main
/// broadcaster on completion. Parallel work becomes legible as a crowd.
///
/// Driven entirely by `subagent.spawn` / `subagent.complete` telemetry
/// signals on the bus — no direct coupling to ChatSession.
@MainActor
final class SwarmController {
    private weak var scene: SCNScene?
    private weak var mainPet: Pet?
    private let screenBounds: NSRect
    private var subscription: AnyCancellable?

    private struct Slot {
        let index: Int
        let position: SCNVector3
        var occupantID: String?
    }

    private struct Orb {
        let pet: Pet
        let slotIndex: Int
    }

    private var slots: [Slot]
    private var activeOrbs: [String: Orb] = [:]
    private let orbScale: CGFloat = 0.32

    init(bus: TelemetryBus, scene: SCNScene, mainPet: Pet, screenBounds: NSRect) {
        self.scene = scene
        self.mainPet = mainPet
        self.screenBounds = screenBounds
        self.slots = Self.makeSlots(in: screenBounds)

        subscription = bus.events.sink { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
    }

    // MARK: - Layout

    /// Four slots in the upper half of the screen, staggered so multiple
    /// orbs don't occlude each other.
    private static func makeSlots(in bounds: NSRect) -> [Slot] {
        let inset: CGFloat = 160
        let yLow = bounds.height * 0.55
        let yHigh = bounds.height * 0.68
        return [
            Slot(index: 0, position: SCNVector3(Double(bounds.minX + inset), Double(yLow), 0), occupantID: nil),
            Slot(index: 1, position: SCNVector3(Double(bounds.minX + inset * 1.8), Double(yHigh), 0), occupantID: nil),
            Slot(index: 2, position: SCNVector3(Double(bounds.maxX - inset * 1.8), Double(yHigh), 0), occupantID: nil),
            Slot(index: 3, position: SCNVector3(Double(bounds.maxX - inset), Double(yLow), 0), occupantID: nil),
        ]
    }

    // MARK: - Event handling

    private func handle(_ event: TelemetryEvent) {
        switch event.signal {
        case TelemetrySignal.subagentSpawn:
            guard let id = event.payload?["id"] as? String else { return }
            let desc = (event.payload?["description"] as? String) ?? ""
            spawn(id: id, description: desc)

        case TelemetrySignal.subagentEnd:
            guard let id = event.payload?["id"] as? String else { return }
            complete(id: id)

        default:
            break
        }
    }

    // MARK: - Lifecycle

    private func spawn(id: String, description: String) {
        guard let scene = scene, let mainPet = mainPet else { return }
        guard activeOrbs[id] == nil else { return }

        let slotIndex = takeSlot(for: id)
        let slot: Slot
        if slotIndex >= 0 {
            slot = slots[slotIndex]
        } else {
            slot = fallbackSlot(mainPet: mainPet)
        }

        let tint = deterministicTint(from: id)
        let orbPet = Pet(form: OrbForm(tint: tint))

        // Start at the main broadcaster's head height, then scurry to the slot.
        let mainPos = mainPet.node.presentation.position
        orbPet.node.position = SCNVector3(
            Double(mainPos.x),
            Double(mainPos.y) + 220,
            Double(mainPos.z)
        )
        orbPet.node.scale = SCNVector3(0.01, 0.01, 0.01)
        scene.rootNode.addChildNode(orbPet.node)

        let move = SCNAction.move(to: slot.position, duration: 0.85)
        move.timingMode = .easeInEaseOut
        let grow = SCNAction.scale(to: Double(orbScale), duration: 0.45)
        grow.timingMode = .easeOut
        orbPet.node.runAction(SCNAction.group([move, grow]))

        // Perpetual "working" pulse while the sub-agent runs.
        let up = SCNAction.scale(by: 1.08, duration: 0.75)
        up.timingMode = .easeInEaseOut
        let down = SCNAction.scale(by: 1.0 / 1.08, duration: 0.75)
        down.timingMode = .easeInEaseOut
        orbPet.node.runAction(
            SCNAction.repeatForever(SCNAction.sequence([up, down])),
            forKey: "swarm.pulse"
        )

        activeOrbs[id] = Orb(pet: orbPet, slotIndex: slotIndex)
        _ = description
    }

    private func complete(id: String) {
        guard let orb = activeOrbs[id], let mainPet = mainPet else { return }

        let orbPet = orb.pet
        orbPet.node.removeAction(forKey: "swarm.pulse")

        let mainPos = mainPet.node.presentation.position
        let target = SCNVector3(
            Double(mainPos.x),
            Double(mainPos.y) + 160,
            Double(mainPos.z)
        )
        let move = SCNAction.move(to: target, duration: 0.55)
        move.timingMode = .easeIn
        let shrink = SCNAction.scale(to: 0.01, duration: 0.55)
        shrink.timingMode = .easeIn
        let fade = SCNAction.fadeOpacity(to: 0, duration: 0.5)

        let group = SCNAction.group([move, shrink, fade])
        orbPet.node.runAction(group) { [weak self] in
            Task { @MainActor in
                orbPet.node.removeFromParentNode()
                self?.releaseSlot(at: orb.slotIndex)
                self?.activeOrbs.removeValue(forKey: id)
                self?.pulseMainPet()
            }
        }
    }

    private func pulseMainPet() {
        guard let mainPet = mainPet else { return }
        let up = SCNAction.scale(by: 1.04, duration: 0.12)
        up.timingMode = .easeOut
        let down = SCNAction.scale(by: 1.0 / 1.04, duration: 0.20)
        down.timingMode = .easeIn
        mainPet.bodyNode.runAction(
            SCNAction.sequence([up, down]),
            forKey: "swarm.absorb"
        )
    }

    // MARK: - Slots

    private func takeSlot(for id: String) -> Int {
        for i in slots.indices where slots[i].occupantID == nil {
            slots[i].occupantID = id
            return i
        }
        return -1
    }

    private func releaseSlot(at index: Int) {
        guard index >= 0, index < slots.count else { return }
        slots[index].occupantID = nil
    }

    private func fallbackSlot(mainPet: Pet) -> Slot {
        let mainPos = mainPet.node.presentation.position
        let jitter = CGFloat.random(in: -100...100)
        return Slot(
            index: -1,
            position: SCNVector3(
                Double(mainPos.x) + Double(jitter),
                Double(mainPos.y) + 280,
                0
            ),
            occupantID: nil
        )
    }

    // MARK: - Deterministic tint

    /// FNV-1a hash → HSB hue. Stable within a run, different per id.
    private func deterministicTint(from id: String) -> NSColor {
        var hash: UInt64 = 14695981039346656037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(
            hue: hue,
            saturation: 0.75,
            brightness: 0.92,
            alpha: 1.0
        )
    }

    /// `bus.events` (a `PassthroughSubject`) retains the sink until
    /// cancelled, so without this the controller + every closure
    /// capture stays alive past deinit. Isolated deinit (SE-0371) so
    /// cancel runs on the @MainActor queue the sink was attached on.
    isolated deinit {
        subscription?.cancel()
    }
}
