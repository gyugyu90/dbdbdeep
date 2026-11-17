import AppKit
import SwiftUI

@MainActor
final class ResultGridDragScroller {
    weak var probe: NSView?
    private var timer: Timer?

    func track(onScroll: @escaping (CGPoint) -> Void) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scroll(onScroll: onScroll) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scroll(onScroll: (CGPoint) -> Void) {
        guard let probe, let window = probe.window else { stop(); return }
        scroll(at: window.mouseLocationOutsideOfEventStream, onScroll: onScroll)
    }

    func scroll(at windowPoint: CGPoint, onScroll: (CGPoint) -> Void) {
        guard let probe,
              let scroll = probe.enclosingScrollView, let document = scroll.documentView else { stop(); return }
        let clip = scroll.contentView
        let point = clip.convert(windowPoint, from: nil)
        let visible = clip.bounds
        let x = Self.offset(point.x, lower: visible.minX, upper: visible.maxX)
        let y = Self.offset(point.y, lower: visible.minY, upper: visible.maxY)
        let origin = CGPoint(x: min(max(0, visible.minX + x), max(0, document.bounds.width - visible.width)),
                             y: min(max(0, visible.minY + y), max(0, document.bounds.height - visible.height)))
        guard origin != visible.origin else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        onScroll(probe.convert(windowPoint, from: nil))
    }

    static func offset(_ point: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        let edge: CGFloat = 18
        if point < lower + edge { return -min(24, max(4, lower + edge - point)) }
        if point > upper - edge { return min(24, max(4, point - upper + edge)) }
        return 0
    }

    deinit { timer?.invalidate() }
}

struct ResultGridScrollProbe: NSViewRepresentable {
    let controller: ResultGridDragScroller

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        controller.probe = view
        return view
    }

    func updateNSView(_ view: Probe, context: Context) { controller.probe = view }
    static func dismantleNSView(_ view: Probe, coordinator: ()) {}

    final class Probe: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
