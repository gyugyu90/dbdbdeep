import AppKit

final class SQLTextFinder {
    private weak var editor: NSTextView?
    private var monitor: Any?

    init(editor: NSTextView) {
        self.editor = editor
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func perform(_ action: NSTextFinder.Action) {
        guard let editor, let window = editor.window else { return }
        (editor as? SQLCompletionTextView)?.onDismissCompletion?()
        if action == .showFindInterface { window.makeFirstResponder(editor) }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        editor.performTextFinderAction(sender)
        if action == .hideFindInterface { window.makeFirstResponder(editor) }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard let editor, let window = editor.window, event.window === window,
              ownsFocus(in: window) else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let action: NSTextFinder.Action
        if modifiers == .command, CommandKeyboard.character(in: event) == "f" { action = .showFindInterface }
        else if modifiers == .command, CommandKeyboard.character(in: event) == "g" { action = .nextMatch }
        else if modifiers == [.command, .shift], CommandKeyboard.character(in: event) == "g" { action = .previousMatch }
        else if event.keyCode == 53, modifiers.isEmpty, editor.enclosingScrollView?.isFindBarVisible == true { action = .hideFindInterface }
        else { return event }
        if !event.isARepeat { perform(action) }
        return nil
    }

    private func ownsFocus(in window: NSWindow) -> Bool {
        guard let editor else { return false }
        if window.firstResponder === editor { return true }
        guard let bar = editor.enclosingScrollView?.findBarView, editor.enclosingScrollView?.isFindBarVisible == true else { return false }
        if let view = window.firstResponder as? NSView, view.isDescendant(of: bar) { return true }
        if let fieldEditor = window.firstResponder as? NSTextView, fieldEditor.isFieldEditor,
           let field = fieldEditor.delegate as? NSView { return field.isDescendant(of: bar) }
        return false
    }
}
