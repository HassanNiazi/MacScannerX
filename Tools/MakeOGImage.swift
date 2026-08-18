// Draws the 1200×630 social preview card used for og:image / twitter:image.
//
//   swift Tools/MakeOGImage.swift docs/social-card.png
//
// Kept as a script rather than a checked-in-only PNG so the card can be
// regenerated when the tagline or the app icon changes.

import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/social-card.png"
let W: CGFloat = 1200, H: CGFloat = 630

let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The context has its origin at the bottom left, but the card is easier to
/// reason about from the top down — every placement below passes a top edge.
func fromTop(_ topY: CGFloat, height: CGFloat) -> CGFloat { H - topY - height }

// Background: the same graphite-blue the app icon uses, so the card and the
// icon read as one family.
NSGradient(colors: [rgb(0x0F1420), rgb(0x1E2740), rgb(0x141A2B)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 115)

// A cyan wash behind the artwork, echoing the icon's scan bar.
ctx.saveGState()
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(0x3FE0FF).withAlphaComponent(0.20).cgColor,
                               rgb(0x3FE0FF).withAlphaComponent(0).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: 930, y: 360), startRadius: 0,
                       endCenter: CGPoint(x: 930, y: 360), endRadius: 470,
                       options: [])
ctx.restoreGState()

// Screenshot first, so the text column can overlap it if it ever grows.
if let shot = NSImage(contentsOfFile: "docs/screenshot-hero.jpg") {
    let frame = NSRect(x: 706, y: fromTop(168, height: 306), width: 452, height: 306)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -8, height: -16), blur: 46,
                  color: NSColor.black.withAlphaComponent(0.6).cgColor)
    rgb(0x0B0F18).setFill()
    NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
    ctx.restoreGState()

    ctx.saveGState()
    NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11).addClip()
    shot.draw(in: frame.insetBy(dx: 1, dy: 1))
    ctx.restoreGState()

    ctx.saveGState()
    rgb(0x4A5878).withAlphaComponent(0.7).setStroke()
    let edge = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
    edge.lineWidth = 1.5
    edge.stroke()
    ctx.restoreGState()
}

// App icon.
if let icon = NSImage(contentsOfFile: "docs/icon.png") {
    icon.draw(in: NSRect(x: 84, y: fromTop(92, height: 116), width: 116, height: 116))
}

func draw(_ text: String, x: CGFloat, topY: CGFloat, size: CGFloat,
          weight: NSFont.Weight, color: NSColor, width: CGFloat = 600) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = size * 0.18
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style
    ]
    // The text lays out from the top edge of this rect downward.
    NSAttributedString(string: text, attributes: attrs)
        .draw(with: NSRect(x: x, y: 0, width: width, height: H - topY),
              options: [.usesLineFragmentOrigin])
}

draw("MacScannerX", x: 84, topY: 240, size: 74, weight: .bold, color: .white)
draw("A free, open-source VueScan\nalternative for macOS",
     x: 86, topY: 336, size: 33, weight: .medium, color: rgb(0x7FE1FF))
draw("Scan over USB, AirScan/eSCL and Image Capture —\nincluding HP printers macOS will not scan from.",
     x: 86, topY: 452, size: 23, weight: .regular, color: rgb(0x9FADC6))
draw("Apache-2.0  ·  macOS 14+  ·  Universal",
     x: 86, topY: 546, size: 20, weight: .semibold, color: rgb(0x6E7C96))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
