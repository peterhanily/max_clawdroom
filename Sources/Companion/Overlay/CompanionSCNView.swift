import AppKit
import SceneKit

final class MaxClawdroomSCNView: SCNView {
    /// Return true to indicate this view consumed the click and should begin
    /// tracking mouseDragged/mouseUp for a potential drag.
    var onMouseDown: ((NSPoint) -> Bool)?
    var onMouseDragged: ((NSPoint) -> Void)?
    /// (location, didDragPastThreshold)
    var onMouseUp: ((NSPoint, Bool) -> Void)?
    /// Right-click at view-local coordinates.
    var onRightMouseDown: ((NSPoint) -> Void)?

    private var tracking = false
    private var didDragPastThreshold = false
    private var downAt: NSPoint?
    private let dragThreshold: CGFloat = 5

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        downAt = local
        didDragPastThreshold = false
        if onMouseDown?(local) == true {
            tracking = true
            return
        }
        tracking = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking else {
            super.mouseDragged(with: event)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if !didDragPastThreshold, let start = downAt,
           hypot(local.x - start.x, local.y - start.y) > dragThreshold {
            didDragPastThreshold = true
        }
        if didDragPastThreshold {
            onMouseDragged?(local)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard tracking else {
            super.mouseUp(with: event)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        onMouseUp?(local, didDragPastThreshold)
        tracking = false
        didDragPastThreshold = false
        downAt = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if onRightMouseDown != nil {
            onRightMouseDown?(local)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}
