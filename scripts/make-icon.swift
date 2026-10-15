import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let shadow = NSShadow(); shadow.shadowColor = color(0x786794).withAlphaComponent(0.16); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
color(0xEDE6FB).setFill()
NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196).fill()
NSShadow().set()
color(0xC5B0EA).setFill()
NSBezierPath(roundedRect: NSRect(x: 250, y: 280, width: 524, height: 440), xRadius: 110, yRadius: 110).fill()
NSBezierPath(rect: NSRect(x: 250, y: 440, width: 524, height: 240)).fill()
color(0xA88AD8).setFill()
NSBezierPath(ovalIn: NSRect(x: 250, y: 620, width: 524, height: 150)).fill()
color(0xE0D3F6).setStroke()
let rim = NSBezierPath(); rim.move(to: NSPoint(x: 276, y: 482)); rim.curve(to: NSPoint(x: 748, y: 482), controlPoint1: NSPoint(x: 365, y: 416), controlPoint2: NSPoint(x: 659, y: 416)); rim.lineWidth = 10; rim.stroke()
color(0x56416F).setFill()
for x in [400.0, 594.0] { NSBezierPath(ovalIn: NSRect(x: x, y: 381, width: 28, height: 34)).fill() }
color(0x56416F).setStroke()
let smile = NSBezierPath(); smile.move(to: NSPoint(x: 470, y: 380)); smile.curve(to: NSPoint(x: 554, y: 380), controlPoint1: NSPoint(x: 482, y: 344), controlPoint2: NSPoint(x: 542, y: 344)); smile.lineWidth = 12; smile.lineCapStyle = .round; smile.stroke()
color(0xE8AAC0).withAlphaComponent(0.75).setFill()
for x in [346.0, 636.0] { NSBezierPath(ovalIn: NSRect(x: x, y: 351, width: 46, height: 21)).fill() }
color(0xF7CC75).setFill()
let star = NSBezierPath(); star.move(to: NSPoint(x: 803, y: 778)); star.line(to: NSPoint(x: 819, y: 737)); star.line(to: NSPoint(x: 860, y: 721)); star.line(to: NSPoint(x: 819, y: 705)); star.line(to: NSPoint(x: 803, y: 664)); star.line(to: NSPoint(x: 787, y: 705)); star.line(to: NSPoint(x: 746, y: 721)); star.line(to: NSPoint(x: 787, y: 737)); star.close(); star.fill()
image.unlockFocus()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
