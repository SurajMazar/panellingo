import Foundation

/// Undo/redo registration for whole-page edits. Every edit stores the previous page value, so any
/// change (text, region geometry, typography, translation, creation/deletion) is reversible.
public final class PageHistory {
    public weak var undoManager: UndoManager?
    /// Called with the page value to restore (on undo or redo).
    public var apply: (ComicPage) -> Void

    public init(undoManager: UndoManager? = nil, apply: @escaping (ComicPage) -> Void) {
        self.undoManager = undoManager
        self.apply = apply
    }

    /// Records that `previous` was replaced by `current`.
    public func record(previous: ComicPage, current: ComicPage, actionName: String) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { h in
            h.apply(previous)
            h.record(previous: current, current: previous, actionName: actionName)
        }
        um.setActionName(actionName)
    }
}
