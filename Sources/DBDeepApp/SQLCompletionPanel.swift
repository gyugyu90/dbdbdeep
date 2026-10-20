import AppKit
import DBDeepCore
import SwiftUI

final class SQLCompletionPanel: NSPanel {
    private var eventMonitor: Any?
    private var focusObserver: NSObjectProtocol?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        setAccessibilityLabel("SQL suggestions")
    }

    func show(_ result: SQLCompletionResult, selected: Int, for editor: NSTextView, choose: @escaping (Int) -> Void, onDismiss: @escaping () -> Void) {
        guard let window = editor.window else { return }
        let rowHeight: CGFloat = 42
        let height = CGFloat(min(result.candidates.count, 6)) * rowHeight + 56
        let width: CGFloat = 360
        let root = SQLCompletionList(candidates: result.candidates, selected: selected, choose: choose)
            .environment(\.colorScheme, editor.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
        contentView = NSHostingView(rootView: root)
        let anchor = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let screen = window.screen?.visibleFrame ?? anchor
        let x = max(screen.minX + 8, min(anchor.minX, screen.maxX - width - 8))
        let y = anchor.minY - height - 4 >= screen.minY ? anchor.minY - height - 4 : min(anchor.maxY + 4, screen.maxY - height)
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        if parent !== window {
            parent?.removeChildWindow(self)
            window.addChildWindow(self, ordered: .above)
        }
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.modifierFlags.contains(.command) { onDismiss() }
                } else if event.window !== self { onDismiss() }
                return event
            }
            focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in onDismiss() }
        }
        orderFront(nil)
    }

    func dismiss() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        eventMonitor = nil
        focusObserver = nil
        orderOut(nil)
        parent?.removeChildWindow(self)
    }
}

private struct SQLCompletionList: View {
    let candidates: [SQLCompletion]
    let selected: Int
    let choose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.purple)
                Text("Schema suggestions").fontWeight(.semibold)
                Spacer()
                Text("\(candidates.count)").foregroundStyle(Theme.secondary)
            }.font(.system(size: 10)).padding(.horizontal, 12).frame(height: 28)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            Button { choose(index) } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: candidate.kind == .column ? "number" : candidate.kind == .view ? "eye" : "tablecells")
                                        .font(.system(size: 12)).foregroundStyle(Theme.purple).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.insertion).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                                        Text(candidate.detail).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if index == selected { Image(systemName: "return").font(.system(size: 10)).foregroundStyle(Theme.purple) }
                                }.padding(.horizontal, 10).frame(height: 42)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == selected ? Theme.tint("lavender") : .clear)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(index)
                                .accessibilityLabel(candidate.name + ", " + candidate.detail)
                                .accessibilityAddTraits(index == selected ? .isSelected : [])
                        }
                    }
                }.onChange(of: selected, initial: true) { _, value in proxy.scrollTo(value, anchor: .center) }
            }
            HStack {
                Text("↑↓ choose  ·  Tab / ↵ insert")
                Spacer()
                Text("Esc close")
            }.font(.system(size: 9)).foregroundStyle(Theme.secondary).padding(.horizontal, 12).frame(height: 28)
        }.foregroundStyle(Theme.ink).background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }
}

final class SQLCompletionTextView: NSTextView {
    var onDismissCompletion: (() -> Void)?
    var onRequestCompletion: (() -> Void)?

    override func complete(_ sender: Any?) { onRequestCompletion?() }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onDismissCompletion?() }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { onDismissCompletion?() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func scrollWheel(with event: NSEvent) {
        onDismissCompletion?()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control {
            onRequestCompletion?()
            return
        }
        if event.modifierFlags.contains(.command) { onDismissCompletion?() }
        super.keyDown(with: event)
    }
}
