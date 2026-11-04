import AppKit

final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    private(set) var lines = SQLLineIndex("")

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ lines: SQLLineIndex) {
        self.lines = lines
        ruleThickness = max(44, CGFloat(String(lines.count).count) * 7 + 18)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(Theme.surface).setFill()
        bounds.fill()
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
        let visible = view.visibleRect.offsetBy(dx: -view.textContainerInset.width, dy: -view.textContainerInset.height)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(Theme.lineNumber)]
        var line = lines.line(at: characters.location)
        while line < lines.count, lines.starts[line] <= NSMaxRange(characters) {
            let character = lines.starts[line]
            let lineRect: NSRect
            if character == lines.length { lineRect = layout.extraLineFragmentRect }
            else {
                let glyph = layout.glyphIndexForCharacter(at: character)
                lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let y = lineRect.minY + view.textContainerInset.height - view.visibleRect.minY + 1
            let label = "\(line + 1)" as NSString
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 9, y: y), withAttributes: attributes)
            line += 1
        }
    }
}
