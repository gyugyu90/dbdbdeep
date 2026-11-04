import AppKit
import SwiftUI

final class ThemedScroller: NSScroller {
    private(set) var expansion: CGFloat = 0
    private(set) var isActive = false
    private var animation: Timer?
    private var collapseWork: DispatchWorkItem?
    private var isTrackingKnob = false
    var knobThickness: CGFloat { 4 + 4 * expansion }

    override class var isCompatibleWithOverlayScrollers: Bool { false }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.canvas).setFill()
        dirtyRect.fill()
        guard isEnabled, knobProportion < 1 else { return }
        let vertical = bounds.height >= bounds.width
        let trackWidth = 2 + 8 * expansion
        let track = vertical
            ? NSRect(x: bounds.midX - trackWidth / 2, y: bounds.minY + 2, width: trackWidth, height: max(0, bounds.height - 4))
            : NSRect(x: bounds.minX + 2, y: bounds.midY - trackWidth / 2, width: max(0, bounds.width - 4), height: trackWidth)
        NSColor(Theme.scrollbarTrack).withAlphaComponent(0.25 + 0.55 * expansion).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackWidth / 2, yRadius: trackWidth / 2).fill()
        var knob = rect(for: .knob)
        if vertical { knob.origin.x = bounds.midX - knobThickness / 2; knob.size.width = knobThickness }
        else { knob.origin.y = bounds.midY - knobThickness / 2; knob.size.height = knobThickness }
        let color = NSColor(Theme.scrollbarThumb).blended(withFraction: expansion, of: NSColor(Theme.purple)) ?? NSColor(Theme.purple)
        color.setFill()
        NSBezierPath(roundedRect: knob, xRadius: knobThickness / 2, yRadius: knobThickness / 2).fill()
    }

    func scrolling(keepExpanded: Bool = false) {
        collapseWork?.cancel()
        setActive(true)
        if !keepExpanded { finishScrolling() }
    }

    func finishScrolling() {
        collapseWork?.cancel()
        guard isActive else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isTrackingKnob else { return }
            self.setActive(false)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingKnob = true
        scrolling(keepExpanded: true)
        super.mouseDown(with: event)
        isTrackingKnob = false
        finishScrolling()
    }

    func stopAnimating() {
        collapseWork?.cancel()
        collapseWork = nil
        animation?.invalidate()
        animation = nil
    }

    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        animation?.invalidate()
        animation = nil
        let target: CGFloat = active ? 1 : 0
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            expansion = target
            needsDisplay = true
            return
        }
        let start = expansion
        let started = ProcessInfo.processInfo.systemUptime
        let duration = active ? 0.16 : 0.24
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
            let eased = 1 - pow(1 - progress, 3)
            self.expansion = start + (target - start) * eased
            self.needsDisplay = true
            if progress == 1 { timer.invalidate(); self.animation = nil }
        }
        animation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { animation?.invalidate(); collapseWork?.cancel() }
}

final class ScrollbarController {
    static func viewportSize(content: NSSize, in frame: NSSize) -> NSSize {
        let gutter = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        var viewport = frame
        for _ in 0..<3 {
            viewport = NSSize(width: max(0, frame.width - (content.height > viewport.height ? gutter : 0)),
                              height: max(0, frame.height - (content.width > viewport.width ? gutter : 0)))
        }
        return viewport
    }

    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var scrollerObservations: [NSKeyValueObservation] = []
    private var installPending = false
    private var lastOrigin: NSPoint
    private var isLiveScrolling = false

    init(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        lastOrigin = scrollView.contentView.bounds.origin
        install()
        scrollerObservations = [
            scrollView.observe(\.verticalScroller) { [weak self] _, _ in self?.scheduleInstall() },
            scrollView.observe(\.horizontalScroller) { [weak self] _, _ in self?.scheduleInstall() },
            scrollView.observe(\.hasVerticalScroller) { [weak self] _, _ in self?.scheduleInstall() },
            scrollView.observe(\.hasHorizontalScroller) { [weak self] _, _ in self?.scheduleInstall() }
        ]
        lastOrigin = scrollView.contentView.bounds.origin
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in self?.boundsChanged() })
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in self?.isLiveScrolling = true })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
            self?.isLiveScrolling = false
            self?.vertical?.finishScrolling()
            self?.horizontal?.finishScrolling()
        })
    }

    private var vertical: ThemedScroller? { scrollView?.verticalScroller as? ThemedScroller }
    private var horizontal: ThemedScroller? { scrollView?.horizontalScroller as? ThemedScroller }

    private func scheduleInstall() {
        guard !installPending else { return }
        installPending = true
        DispatchQueue.main.async { [weak self] in
            self?.installPending = false
            self?.install()
        }
    }

    func install() {
        guard let scrollView else { return }
        var changed = false
        if scrollView.hasVerticalScroller, !(scrollView.verticalScroller is ThemedScroller) {
            scrollView.verticalScroller = ThemedScroller()
            changed = true
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is ThemedScroller) {
            scrollView.horizontalScroller = ThemedScroller()
            changed = true
        }
        if scrollView.scrollerStyle != .legacy { scrollView.scrollerStyle = .legacy }
        if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
        if changed {
            scrollView.tile()
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func boundsChanged() {
        guard let scrollView else { return }
        let origin = scrollView.contentView.bounds.origin
        if origin.y != lastOrigin.y { vertical?.scrolling(keepExpanded: isLiveScrolling) }
        if origin.x != lastOrigin.x { horizontal?.scrolling(keepExpanded: isLiveScrolling) }
        lastOrigin = origin
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        vertical?.stopAnimating()
        horizontal?.stopAnimating()
    }
}

extension View {
    func themedScrollbars() -> some View { background(ScrollbarInstaller().frame(width: 0, height: 0)) }
}

private struct ScrollbarInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.scheduleInstall() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.controller = nil }

    final class Probe: NSView {
        var controller: ScrollbarController?
        private weak var styledScrollView: NSScrollView?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleInstall() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleInstall() }
        override func layout() { super.layout(); scheduleInstall() }

        func scheduleInstall() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                if self.styledScrollView !== scroll {
                    self.controller = ScrollbarController(scroll)
                    self.styledScrollView = scroll
                } else { self.controller?.install() }
            }
        }
    }
}
