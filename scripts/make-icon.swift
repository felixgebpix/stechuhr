// Draws the Stechuhr app icon (a punch clock with a time card) as a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Coordinates: origin bottom-left.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow + body gradient
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.35).cgColor)
color(0x1E2A40).setFill()
bodyPath.fill()
ctx.restoreGState()
NSGradient(starting: color(0x34476A), ending: color(0x18213A))!.draw(in: bodyPath, angle: -90)

// Subtle top highlight
let highlight = NSBezierPath(roundedRect: body.insetBy(dx: 6, dy: 6), xRadius: 180, yRadius: 180)
color(0xFFFFFF, 0.08).setStroke()
highlight.lineWidth = 4
highlight.stroke()

// Time card slot at the bottom
let slot = NSRect(x: 322, y: 196, width: 380, height: 44)
color(0x0D1322).setFill()
NSBezierPath(roundedRect: slot, xRadius: 22, yRadius: 22).fill()

// Time card sticking out of the slot
let card = NSRect(x: 382, y: 214, width: 260, height: 150)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(0x000000, 0.4).cgColor)
color(0xF4EBDD).setFill()
NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
ctx.restoreGState()
// Card lines and punched marks
for i in 0..<3 {
    let y = card.maxY - 40 - CGFloat(i) * 34
    color(0x1E2A40, 0.25).setFill()
    NSBezierPath(roundedRect: NSRect(x: card.minX + 26, y: y, width: 140, height: 10), xRadius: 5, yRadius: 5).fill()
    color(0xE8693A).setFill()
    NSBezierPath(ovalIn: NSRect(x: card.maxX - 62, y: y - 6, width: 22, height: 22)).fill()
}
// Re-draw slot lip over the card bottom so it looks inserted
color(0x0D1322).setFill()
NSBezierPath(roundedRect: NSRect(x: slot.minX, y: slot.minY, width: slot.width, height: 26), xRadius: 13, yRadius: 13).fill()

// Clock
let center = CGPoint(x: 512, y: 600)
let r: CGFloat = 250
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.35).cgColor)
color(0xE0A458).setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
ctx.restoreGState()
NSGradient(starting: color(0xF0B86A), ending: color(0xC98A3E))!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)), angle: -90)
let face = r - 26
color(0xF7F0E4).setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - face, y: center.y - face, width: 2 * face, height: 2 * face)).fill()

// Ticks
for i in 0..<60 {
    let a = CGFloat(i) / 60 * 2 * .pi
    let major = i % 5 == 0
    let outer = face - 16, inner = face - (major ? 58 : 32)
    let p = NSBezierPath()
    p.move(to: CGPoint(x: center.x + sin(a) * inner, y: center.y + cos(a) * inner))
    p.line(to: CGPoint(x: center.x + sin(a) * outer, y: center.y + cos(a) * outer))
    p.lineWidth = major ? 14 : 5
    p.lineCapStyle = .round
    color(0x1E2A40, major ? 1 : 0.45).setStroke()
    p.stroke()
}

func hand(angleDeg: CGFloat, length: CGFloat, width: CGFloat, tint: NSColor) {
    let a = angleDeg / 180 * .pi
    let p = NSBezierPath()
    p.move(to: CGPoint(x: center.x - sin(a) * 26, y: center.y - cos(a) * 26))
    p.line(to: CGPoint(x: center.x + sin(a) * length, y: center.y + cos(a) * length))
    p.lineWidth = width
    p.lineCapStyle = .round
    tint.setStroke()
    p.stroke()
}
hand(angleDeg: -60, length: 120, width: 26, tint: color(0x1E2A40))   // hour ≈ 10
hand(angleDeg: 60, length: 172, width: 18, tint: color(0x1E2A40))    // minute ≈ 10
hand(angleDeg: 160, length: 186, width: 7, tint: color(0xE8693A))    // second
color(0xE8693A).setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)).fill()
color(0xF7F0E4).setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Icon: \(out)")
