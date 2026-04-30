# Overlay refactor — share `Pet` + `ChatSession` across screens

**Status:** Stages 1 + 2 shipped 2026-04-25. Stage 3 deferred (needs multi-monitor hardware to validate the global-coord change).

## Stage 2 — DONE

Hoisted to `AppDelegate` (single shared instance, was per-overlay):

- `ChatSession` (with all its environmentSensors / voiceEngine / memory /
  userModelStore / sessionStore wirings — those always pointed at the
  same shared singletons, so the wirings collapsed naturally)

Wins on a 4-monitor setup:
- 1× `claude` subprocess instead of 4× — biggest single cost win
- 1× live conversation state across overlays
- Chat opened on any screen surfaces the same conversation

Stage 2 trade-offs:
- Per-overlay TelemetryBus + BindingEngine + SwarmController stay per-overlay
  (kept reactive Pets locally; SwarmController orbs spawn per-screen as
  before).
- Only the PRIMARY overlay wires `chatSession.actionHandler` /
  `.telemetryBus` / `.onTurnStart` etc. Secondary overlays would clobber
  primary's references on app launch.
- Consequence: agent-driven body changes (`set_part_color`, gestures,
  bindings) show on the PRIMARY Pet only. Secondary screens' Pets are
  decorative — they walk, blink, and respond to drag, but don't react
  to chat. Stage 3 fixes this by sharing the Pet itself.

`OverlayController.init` signature gained `chatSession: ChatSession`.
Per-overlay `ChatSession` construction + 5 wiring lines deleted; three
wiring blocks (telemetryBus, actionHandler, onTurnStart-trio) gated on
`screen === NSScreen.main`.

## Stage 1 — DONE

Hoisted to `AppDelegate` (single shared instance, was per-overlay):

- `EnvironmentSensors` (with its `modeManager` + `editorAwareness` wiring)
- `EditorAwareness`
- `UndoStack`
- `CompanionState`
- `ChatTheme`
- `CompanionModeManager`
- `PreferenceLearner.shared.start()` call site

Wins on a 4-monitor setup:
- 1× `EnvironmentSensors` polling (was 4×) — material CPU saving
- 1× `EditorAwareness` AX query (was 4×) — material CPU saving
- Single undo timeline across overlays
- Consistent mode / stage / theme across screens
- 6 fewer `Combine` observers per launched screen

`OverlayController.init` signature grew (5 → 11 args) and body lost ~10
lines. No coord change required — these objects aren't Pet-coupled.

## Stage 3 — TODO (the global-coord refactor)

Still per-overlay; this is the heavy work that needs multi-monitor
hardware to validate:

- `SCNScene`, `Pet`, `Locomotion`, `SwarmController`, `Tour`, `Autonomy`,
  `AnnotationOverlay`, `AgencyStrip`, `Reflex`, `SoulTintDrift`,
  `UserModelSynthesiser`, `WorkWatcher`, `WorkStateTracker`,
  `WorkStateEffects`, `ExpressionDriver`, `StageDriver`, `subtitleBar`

(`TelemetryBus`, `BindingEngine` stay per-overlay because they're
Pet-coupled — they share the Pet's lifecycle.)

After Stage 3, agent body actions (`set_part_color`, gestures, bindings)
will affect ALL screens' Pets, not just primary's. The blocker is the
coordinate-system change (per-screen scenes → one shared scene with N
cameras). Details below — execute when on multi-monitor hardware so you
can verify drag-handoff between screens and screen attach/detach.

The design below remains executable as-is for Stage 3.

---

## Goal

Today, on a 4-monitor setup, max_clawdroom builds 4× of:

`Pet`, `Locomotion`, `ChatSession`, `TelemetryBus`, `BindingEngine`,
`EnvironmentSensors`, `SwarmController`, `EditorAwareness`, `CompanionState`,
`ChatTheme`, `CompanionModeManager`, `UndoStack`.

Plus a separate `claude` subprocess per `ChatSession`. Footprint scales O(N
screens). After this refactor: each of those exists exactly once, owned by
`AppDelegate`. Each screen still gets its own `NSWindow`, `SCNView`, and
`SCNCamera` rendering the shared `SCNScene`.

`AppDelegate` already shares `VoiceEngine`, `MemoryStore`, `SessionStore`,
`UserModelStore`. This extends the same pattern to the rest.

---

## What needs to move

### Hoisted to `AppDelegate` (single instance)

| Object | Why it's safe to share |
|---|---|
| `SCNScene` | One scene rendered by N views with N cameras is supported by SceneKit. |
| `Pet` (the `SCNNode` + rig) | Pet's world position is a single point; per-screen cameras frame whichever screen contains him. |
| `Locomotion` | Walks Max via `pet.node.position` — works on a global coord space. |
| `TelemetryBus` | Pure pub/sub. |
| `BindingEngine` | Drives the shared Pet from bus events. |
| `EnvironmentSensors` | Polls system state (frontmost app, time, etc.). Same data on every screen. |
| `EditorAwareness` | Polls AX. Same data on every screen. |
| `UndoStack` | Single undo timeline. |
| `CompanionState` | Stage / mood. Same on every screen. |
| `ChatTheme` | Same theme everywhere. |
| `CompanionModeManager` | One mode at a time. |
| `ChatSession` | One conversation; the chat bubble surfaces on the focused screen. |
| `SwarmController` | Spawn destinations recomputed against the active screen each spawn. |
| `Tour`, `ExpressionDriver`, `StageDriver` | Single instance, shared. |
| `Autonomy`, `AnnotationOverlay`, `AgencyStrip`, `SubtitleBar` | Currently primary-only via `screen === NSScreen.main` guard — hoisting them up makes that gate disappear. |
| `Reflex`, `SoulTintDrift`, `UserModelSynthesiser`, `WorkWatcher`, `WorkStateTracker`, `WorkStateEffects` | Same — currently primary-only. |

### Stays per-`OverlayController` (per-screen)

| Object | Why it stays per-screen |
|---|---|
| `NSWindow` | One window per screen by definition. |
| `CompanionSCNView` | One view per screen. |
| `SCNCamera` + `cameraNode` | Per-screen framing; added to the shared scene. |
| `framerateTimer` | Adapts framerate per visible/focused state of *this* screen. |
| `cursorGazeController` | Mouse-driven, per-screen geometry. |
| `crtEffects` | `SCNTechnique` attaches to one `SCNView`. |
| `chat` (ChatBubbleController) | Chat bubble opens on the focused screen only — bubble window. |
| Drag state, follow-mouse state, occlusion observer | Per-window. |

---

## Coordinate-system change

This is the subtle bit and the highest-risk part of the refactor.

**Today:** each `OverlayController` has its own `SCNScene`. Pet's coords are
local to that scene's `screen.frame` — `(screen.width/2, baseY, 0)` is "center
of THIS screen's view".

**After:** one shared `SCNScene` with global coords (the union of all
`NSScreen.frame`s, which on macOS share a single coordinate system). Pet's
`node.position` is a single global point. Each per-screen `cameraNode` sits at
`(screen.midX, screen.midY, 1500)` with `orthographicScale = screen.height / 2`,
framing only its own screen. Pet appears on whichever screen's frustum his
world point falls in.

### Concrete consequences

1. **Initial position:** primary screen's center, in global coords.
2. **Drag clamp:** instead of clamping to `screen.frame.width`, clamp to the
   active screen (NSScreen containing pet's current x). `handleDrag` already
   knows which screen it's on (the dispatching `OverlayController.screen`).
3. **`petScreenRect()`:** today converts via `scnView.convert` then
   `window.convertPoint(toScreen:)`. After refactor: pet's world coords ARE
   screen coords (orthographic 1:1), so `petScreenRect()` becomes a pure
   computation off `pet.node.presentation.position` + `pet.form.hitBoundsRelative`
   + `pet.node.presentation.scale`. No view conversions needed.
4. **`onSummon`:** instead of "is this MY screen", any overlay can call
   `pet.moveTo(globalX, globalY)` and the pet shows up on whichever screen
   contains the cursor.
5. **`tickFollowMouse`:** drop the per-overlay "is the mouse on my screen"
   check. There's one Pet; one global mouse; one global moveTo.

---

## Step-by-step execution plan

### Step 0 — Proof harness (10-30 min)

Write a temp scratch (`MultiViewProof.swift`, deleted before commit):

```swift
// Two NSWindows, two SCNViews, ONE SCNScene with one cube SCNNode,
// two SCNCamera nodes added to the scene, each view's pointOfView
// pointing at one camera. Confirm both views render the cube.
```

Just verifying Apple's API works as documented. If this fails, the whole
refactor is moot; pick a different architecture (e.g. one Pet, N copies of
its rig — uglier but works).

### Step 1 — `AppOverlayDeps` struct (30 min)

`Sources/Companion/Overlay/AppOverlayDeps.swift`:

```swift
import AppKit
import Combine
import SceneKit

/// Shared dependencies passed to every `OverlayController`. Hoisted out
/// of per-overlay ownership so multi-monitor footprint scales O(1)
/// instead of O(screens).
@MainActor
struct AppOverlayDeps {
    let scene: SCNScene
    let pet: Pet
    let locomotion: Locomotion
    let voice: VoiceEngine
    let memory: MemoryStore
    let sessionStore: SessionStore
    let userModelStore: UserModelStore
    let telemetryBus: TelemetryBus
    let bindingEngine: BindingEngine
    let environmentSensors: EnvironmentSensors
    let editorAwareness: EditorAwareness
    let undoStack: UndoStack
    let companionState: CompanionState
    let chatTheme: ChatTheme
    let modeManager: CompanionModeManager
    let chatSession: ChatSession
    let swarmController: SwarmController
    let tour: TourController
    // Driver / autonomy are app-singletons too; held weakly so OverlayController
    // can resolve them without owning their lifecycle.
    weak var autonomy: AutonomyController?
    weak var annotationOverlay: AnnotationOverlay?
}
```

### Step 2 — Refactor `AppDelegate.applicationDidFinishLaunching` (60-90 min)

Today (line 99-107) AppDelegate constructs the OverlayControllers in a map
over `NSScreen.screens` after creating shared `voice`, `memory`,
`sessionStore`, `userModelStore`. Extend that block to construct *all* the
shared dependencies, then build the deps struct, then map screens to
OverlayControllers passing the deps.

Order matters — Pet needs the scene, BindingEngine needs Pet, ChatSession's
context needs Pet+BindingEngine+memory+etc. Build a single linear
construction sequence in AppDelegate, reusing the existing line 264-372
sequence from OverlayController as the template (it already worked there).

### Step 3 — Refactor `OverlayController.init` (90 min)

New signature: `init(screen: NSScreen, deps: AppOverlayDeps)`.

Body shrinks to:
- Stash `screen`, `deps`, `window`
- Build per-screen `SCNCamera` + `cameraNode`, add to `deps.scene.rootNode`
- Build `CompanionSCNView`, set `scene = deps.scene`, `pointOfView = cameraNode`
- Wire mouse handlers
- Per-screen observer setup (occlusion, lid)
- CRT effects wiring
- Subtitle bar (primary only — keep this gate, or hoist; agent's choice)

Delete: every line constructing one of the now-shared objects. Properties
become `let` references into `deps`. Lifecycle hooks into the shared chat
session move to AppDelegate (e.g. `chatSession.onTurnStart` should be set
once at app launch, not per-overlay).

### Step 4 — `Locomotion` global-bounds (20 min)

Today: `Locomotion(pet:bounds:)` where `bounds = screen.frame`. After:
`Locomotion(pet:)` and a per-step `activeScreen()` lookup:

```swift
private func activeScreen() -> NSScreen {
    let pos = pet.node.presentation.position
    return NSScreen.screens.first {
        $0.frame.contains(CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y)))
    } ?? NSScreen.main ?? NSScreen.screens.first!
}
```

Use `activeScreen().frame` to clamp walks. Walks across screen boundaries
become natural (Max wanders from primary to secondary, his world position
crosses the screen boundary, the new screen's camera now sees him).

### Step 5 — `SwarmController` global-coords (15 min)

Slot positions get recomputed against `activeScreen().frame` on each spawn.
Same pattern as Locomotion.

### Step 6 — Notification observer dedup (30 min)

In OverlayController today, observers like `companionFarewellRequested`,
`companionGravityChanged`, `companionVoiceChanged`, `companionLidClosing`,
`companionTapDetected`, `companionModeRequest`, `companionStartTour`,
`companionCrtEffectsChanged`, `companionAccessibilityChanged`, `NSProcessInfoPowerStateDidChange`
fire once per overlay. After hoisting, register them once on AppDelegate.
Per-screen observers (`NSWindow.didChangeOcclusionStateNotification` for
THIS window) stay per-overlay.

`onLidClosing`/`onLidOpening`/`onTapDetected` move to AppDelegate (they
affect the shared Pet). Per-overlay window-occlusion still pauses periodic
blink/jitter when no screen is showing the Pet — but that needs
union-of-occlusion logic now: only stop blink when ALL windows are
occluded.

### Step 7 — Build + smoke test (30 min)

`swift build` clean. Then on real multi-monitor hardware:

- Single monitor: nothing should change visibly.
- Two monitors: Max appears once (on primary by default). Drag him over
  to the second monitor — verify he renders there.
- Plug/unplug second monitor: pet stays on remaining monitor; no crashes.
- Open chat: bubble opens on whichever monitor Pet is currently on (or
  always primary — design choice; recommend "current Pet's monitor").
- Autonomy ping: fires once, not N times.
- Lid close (laptop closes): Pet goes to sleep once.
- Farewell op: chat closes once.

### Step 8 — Commit

```
Hoist Pet, ChatSession, and shared state to AppDelegate

Multi-monitor footprint scales O(1) per shared object instead of
O(screens). OverlayController becomes a render-only viewport.

Closes the "Known gaps" item from CHANGELOG: "every overlay spawns
its own ChatSession, MemoryStore, SessionStore, VoiceEngine,
BindingEngine".
```

---

## Risks (honest)

1. **Pet position semantics.** Today `pet.form.baseY` is in per-screen
   coords. After refactor, baseY needs to be relative to the screen
   containing the pet (e.g. `activeScreen().frame.minY + form.baseY`).
   Locomotion's "settle to ground" needs the same fix. If this is wrong
   the pet ends up off the bottom of every monitor.

2. **Camera ortho scale on screen detach.** `reflectScreenChange()` today
   updates `cam.orthographicScale = screen.height/2`. After refactor each
   per-screen camera still has its own; reflectScreenChange stays the same
   per-overlay. Verify nothing else assumes the scene has one camera.

3. **`scnView.hitTest`** — operates on what the view CAN see (its own
   frustum). After refactor, hitTest still works per-view (the view's
   pointOfView is its own camera). Drag-detection should be unchanged.

4. **`crtEffects` per-overlay** — each SCNView gets its own SCNTechnique
   (already how it works). Net: still N× CRT cost on N monitors. Not
   addressed by this refactor; that's a separate "CRT primary-only"
   change worth ~5 LOC if you want it.

5. **Race on first-launch pet position.** AppDelegate constructs Pet
   before any OverlayController exists, so Pet has no scene-rendering
   context yet. Set initial position to `NSScreen.main?.frame.center ??
   .zero`. The first OverlayController's camera will pick it up
   immediately on first frame.

6. **Drag handoff between screens.** When user drags Pet from screen 1's
   region into screen 2's region, the drag is routed through screen 1's
   OverlayController (it received the mouseDown). The world coord update
   works fine, but the *cursor* is now over screen 2. AppKit's
   mouseDragged events keep flowing to the screen-1 window until
   mouseUp. After mouseUp, the next mouseDown originates from screen 2's
   overlay. Test this carefully; the user might see a weird "Pet jumps"
   effect if global coords aren't applied consistently.

---

## What this refactor does NOT do (out of scope, separate sessions)

- CRT primary-only optimisation
- Per-screen `backingScaleFactor` propagation to CRTTechnique uniforms
- Pattern texture @2x rendering on Retina displays
- Max's Room garden expansion (running threads / sparkline / contradictions)
- L10n migration completion (Settings + Tour copy ~110 strings remaining)

---

## Companion files

- `Companion/CHANGELOG.md` "Known gaps" — remove the duplication line on
  successful completion of this refactor.
- `Companion/README.md` — no update needed; docs already describe
  multi-monitor support.
- `Companion/Sources/Companion/Overlay/AppOverlayDeps.swift` — new file.
