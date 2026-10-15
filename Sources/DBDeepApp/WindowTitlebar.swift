import AppKit
import SwiftUI

struct WindowTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarSurface { TitlebarSurface() }
    func updateNSView(_ nsView: TitlebarSurface, context: Context) {}
}

final class TitlebarSurface: NSView {
    private var eventMonitor: Any?
    private var restoreFrame: NSRect?
    private let leadingControlsWidth: CGFloat = 80
    private let trailingControlsWidth: CGFloat = 160

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window, event.clickCount == 2,
                  !window.styleMask.contains(.fullScreen), self.bounds.height > 0 else { return event }
            let header = self.convert(self.bounds, to: nil)
            let point = event.locationInWindow
            guard point.y >= header.minY,
                  point.x >= self.leadingControlsWidth,
                  point.x < header.maxX - self.trailingControlsWidth else { return event }
            self.toggleMaximize(window)
            return nil
        }
    }

    private func toggleMaximize(_ window: NSWindow) {
        guard let screen = window.screen else { return }
        let available = screen.visibleFrame
        let frame = window.frame
        let maximized = abs(frame.minX - available.minX) < 1 && abs(frame.minY - available.minY) < 1 &&
            abs(frame.width - available.width) < 1 && abs(frame.height - available.height) < 1
        if maximized {
            if let restoreFrame {
                window.setFrame(restoreFrame, display: true, animate: true)
                self.restoreFrame = nil
            } else {
                window.zoom(nil)
            }
        } else {
            restoreFrame = frame
            window.setFrame(available, display: true, animate: true)
        }
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
}
