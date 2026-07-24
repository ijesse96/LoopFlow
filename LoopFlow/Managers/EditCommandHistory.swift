import Foundation

/// Snapshot-based undo/redo for project edits (clip + selection).
@MainActor
final class EditCommandHistory {
    private var undoStack: [LoopFlowProject] = []
    private var redoStack: [LoopFlowProject] = []
    private let limit = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func push(_ project: LoopFlowProject) {
        undoStack.append(project)
        if undoStack.count > limit {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo(current: LoopFlowProject) -> LoopFlowProject? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    func redo(current: LoopFlowProject) -> LoopFlowProject? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
