import Combine
import Foundation

/// Bounded stack of reverse closures for agent-authored mutations.
/// The agent drives the body via action tags; each undoable op pushes an
/// `Entry` here so the user can `⌘Z` the last change if they dislike it.
///
/// Reverts are not themselves pushed — undo unwinds history, it does not
/// extend it. Transient gestures (look_around, jitter, greet) never push.
@MainActor
final class UndoStack {
    struct Entry {
        let op: String
        let reverse: () -> Void
    }

    private var entries: [Entry] = []
    let maxDepth: Int

    /// Emits the op name each time a new entry is pushed. The chat chrome
    /// subscribes to show a brief 🛠 glyph so the user knows state changed.
    private let pushSubject = PassthroughSubject<String, Never>()
    var pushes: AnyPublisher<String, Never> { pushSubject.eraseToAnyPublisher() }

    @Published private(set) var depth: Int = 0

    init(maxDepth: Int = 32) {
        self.maxDepth = maxDepth
    }

    func push(_ entry: Entry) {
        entries.append(entry)
        if entries.count > maxDepth {
            entries.removeFirst(entries.count - maxDepth)
        }
        depth = entries.count
        pushSubject.send(entry.op)
    }

    /// Pop the most recent entry and run its reverse. Returns true if an
    /// entry was undone, false if the stack was empty.
    @discardableResult
    func undo() -> Bool {
        guard let entry = entries.popLast() else { return false }
        depth = entries.count
        entry.reverse()
        return true
    }

    func clear() {
        entries.removeAll()
        depth = 0
    }
}
