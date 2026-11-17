import AppKit
import SwiftUI

struct ResultsShortcut<Content: View>: NSViewRepresentable {
    let canRefresh: Bool
    let refresh: () -> Void
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> ResultsShortcutView {
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        let view = ResultsShortcutView(content: host)
        view.canRefresh = canRefresh
        view.refresh = refresh
        return view
    }

    func updateNSView(_ view: ResultsShortcutView, context: Context) {
        withTransaction(context.transaction) {
            (view.content as? NSHostingView<Content>)?.rootView = content()
        }
        view.canRefresh = canRefresh
        view.refresh = refresh
    }
}

final class ResultsShortcutView: NSView {
    let content: NSView
    var canRefresh = false
    var refresh: () -> Void = {}
    private var monitor: Any?

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private var hasResultsFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "r", hasResultsFocus else { return event }
            if canRefresh && !event.isARepeat {
                window.makeFirstResponder(self)
                refresh()
            }
            return nil
        }
        if (event.type == .leftMouseDown || event.type == .rightMouseDown),
           bounds.contains(convert(event.locationInWindow, from: nil)), !hasResultsFocus {
            window.makeFirstResponder(self)
        }
        return event
    }
}
