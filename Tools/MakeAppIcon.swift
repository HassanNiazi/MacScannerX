// Draws the MacScannerX app icon and writes one PNG per .icns slot.
//
//   swift Tools/MakeAppIcon.swift <out.iconset>
//
// Everything is vector work in a nominal 1024×1024 space, re-drawn (not
// resampled) at each size, so the 16pt slot stays as crisp as the 1024pt one.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry helpers

/// Apple's icon silhouette is a superellipse, not a rounded rectangle — the
/// corners have continuous curvature. n = 5 matches the system shape closely.
func squirclePath(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB,
               colors: stops.map { $0.0 } as CFArray,
               locations: stops.map { $0.1 })!
}

func fillVertical(_ ctx: CGContext, _ rect: CGRect, _ stops: [(CGColor, CGFloat)]) {
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.drawLinearGradient(gradient(stops),
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY),
                           options: [])
    ctx.restoreGState()
}

// MARK: - The icon

func drawIcon(into ctx: CGContext, size: CGFloat) {
    // Below 64px the fine marks stop resolving, so those slots get a simplified
    // variant rather than a shrunk one.
    let compact = size <= 64

    ctx.saveGState()
    ctx.scaleBy(x: size / 1024, y: size / 1024)   // draw in 1024-space, always
    ctx.setShouldAntialias(true)

    // Content sits in the inner 824pt square; the surrounding margin is where
    // the system expects the icon's shadow to live.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(in: plate)

    // Body — deep graphite-blue, the way scanner hardware reads.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x000000, 0.38))
    ctx.addPath(shape)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    fillVertical(ctx, plate, [(rgb(0x4E608C), 0), (rgb(0x2A3450), 0.55), (rgb(0x151C2E), 1)])

    // Top gloss, fading out by the middle.
    fillVertical(ctx, CGRect(x: 100, y: 560, width: 824, height: 364),
                 [(rgb(0xFFFFFF, 0.16), 0), (rgb(0xFFFFFF, 0.0), 1)])
    ctx.restoreGState()

    // Edge definition so the icon does not melt into a dark dock.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // The page on the platen.
    let page = CGRect(x: 297, y: 242, width: 430, height: 540)
    let barRect = compact
        ? CGRect(x: page.minX - 52, y: 330, width: page.width + 104, height: 40)
        : CGRect(x: page.minX - 48, y: 340, width: page.width + 96, height: 22)
    let pagePath = CGPath(roundedRect: page, cornerWidth: 26, cornerHeight: 26, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: rgb(0x05070E, 0.55))
    ctx.addPath(pagePath)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(pagePath)
    ctx.clip()
    fillVertical(ctx, page, [(rgb(0xFFFFFF), 0), (rgb(0xE7EEF8), 1)])

    // Text on the page: a heading plus body lines. Deliberately few and thick —
    // anything finer turns to mush below 32pt.
    // Content stops at the bar: what is above has been scanned, what is below
    // has not. The 16/32pt slots get fewer, fatter marks — at those sizes a
    // 24pt line lands on less than one pixel and turns to grey mush.
    let heading = compact
        ? CGRect(x: 353, y: 660, width: 208, height: 48)
        : CGRect(x: 353, y: 676, width: 208, height: 34)
    ctx.setFillColor(rgb(0x93A8C8))
    ctx.addPath(CGPath(roundedRect: heading,
                       cornerWidth: heading.height / 2, cornerHeight: heading.height / 2, transform: nil))
    ctx.fillPath()

    let lines: [(CGFloat, CGFloat)] = compact
        ? [(580, 318), (500, 318), (420, 250)]
        : [(604, 318), (548, 318), (492, 268), (436, 318), (380, 214)]
    let lineHeight: CGFloat = compact ? 40 : 24
    ctx.setFillColor(rgb(0xBFCEE3))
    for (y, width) in lines {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 353, y: y, width: width, height: lineHeight),
                           cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
        ctx.fillPath()
    }

    // Light spilling off the scan bar, brightest at the bar itself.
    fillVertical(ctx, CGRect(x: page.minX, y: barRect.maxY, width: page.width, height: 160),
                 [(rgb(0x3FE0FF, 0.0), 0), (rgb(0x3FE0FF, compact ? 0.5 : 0.38), 1)])
    ctx.restoreGState()

    // The scan bar itself — overhangs the page on both sides, which is what
    // makes this read as a scanner rather than a document.
    let barPath = CGPath(roundedRect: barRect,
                         cornerWidth: barRect.height / 2, cornerHeight: barRect.height / 2, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 56, color: rgb(0x3FE0FF, 0.95))
    ctx.setFillColor(rgb(0xE8FBFF))
    ctx.addPath(barPath)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(barPath)
    ctx.clip()
    // Small slots skip the white core — it washes the bar out to a grey smear.
    fillVertical(ctx, barRect, compact
        ? [(rgb(0x8FEEFF), 0), (rgb(0x18C4F5), 1)]
        : [(rgb(0xFFFFFF), 0), (rgb(0x35D6FF), 1)])
    ctx.restoreGState()

    ctx.restoreGState()
}

// MARK: - Render

func render(size: Int) -> CGImage {
    let ctx = CGContext(data: nil,
                        width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(into: ctx, size: CGFloat(size))
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("error: cannot write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: swift Tools/MakeAppIcon.swift <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// The slot list iconutil expects.
let slots: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (size, name) in slots {
    write(render(size: size), to: outDir.appendingPathComponent(name))
}
print("wrote \(slots.count) slots to \(outDir.path)")
