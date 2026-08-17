import Foundation
import CoreGraphics
import AppKit

/// A synthetic HP DeskJet 2300 so the whole app — crop, filters, colour, output —
/// is exercisable with no hardware attached. Renders a scanner-plausible target:
/// paper white with a slight platen gradient, text blocks, a colour bar, and
/// sensor noise scaled to the requested resolution.
final class SimulatedBackend: ScannerBackend {

    static let deviceID = "sim:hp-deskjet-2300"

    private(set) var devices: [ScannerDeviceInfo] = [
        ScannerDeviceInfo(
            id: SimulatedBackend.deviceID,
            name: "HP DeskJet 2300 series",
            model: "DeskJet 2331 (simulated)",
            transport: .simulated,
            bedSizeMM: CGSize(width: 215.9, height: 297.0),
            supportedSources: [.flatbed],
            supportedResolutions: [75, 100, 150, 200, 300, 600, 1200],
            isReady: true
        )
    ]

    private var cancelled = false

    func startDiscovery(onChange: @escaping ([ScannerDeviceInfo]) -> Void) {
        DispatchQueue.main.async { [devices] in onChange(devices) }
    }
    func stopDiscovery() { }

    func probe(deviceID: String) async throws -> ScannerDeviceInfo {
        guard let d = devices.first(where: { $0.id == deviceID }) else {
            throw ScanError.deviceUnavailable(deviceID)
        }
        return d
    }

    func cancel() { cancelled = true }

    func scan(deviceID: String, request: ScanRequest, progress: @escaping ScanProgress) async throws -> [ScanPage] {
        cancelled = false
        // The real 2300 takes ~10 s for a 300 dpi A4 page; scale a token delay
        // off the pixel count so progress feels honest without being tedious.
        let steps = 12
        for i in 0...steps {
            if cancelled { throw ScanError.cancelled }
            progress(Double(i) / Double(steps),
                     request.isPreview ? "Previewing" : "Scanning at \(request.resolutionDPI) dpi")
            try await Task.sleep(nanoseconds: request.isPreview ? 40_000_000 : 90_000_000)
        }
        let image = try Self.render(request: request)
        return [ScanPage(image: image, dpi: request.resolutionDPI, index: 0)]
    }

    // MARK: Synthetic page

    static func render(request: ScanRequest) throws -> CGImage {
        let dpi = Double(request.resolutionDPI)
        let bedW = 215.9, bedH = 297.0
        let pxW = max(16, Int((request.areaMM.width / 25.4 * dpi).rounded()))
        let pxH = max(16, Int((request.areaMM.height / 25.4 * dpi).rounded()))
        // Guard against a 1200 dpi full-bed request eating 400 MB in the simulator.
        let cap = 40_000_000
        let scale = min(1.0, (Double(cap) / Double(pxW * pxH)).squareRoot())
        let w = max(16, Int(Double(pxW) * scale))
        let h = max(16, Int(Double(pxH) * scale))

        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ScanError.transferFailed("could not allocate \(w)x\(h) bitmap")
        }

        let W = Double(w), H = Double(h)
        ctx.setFillColor(CGColor(red: 0.97, green: 0.965, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // Platen light falloff toward the hinge edge.
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let grad = CGGradient(colorsSpace: space,
                                 colors: [CGColor(gray: 0, alpha: 0.0),
                                          CGColor(gray: 0, alpha: 0.06)] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H),
                                   end: CGPoint(x: 0, y: 0), options: [])
        }

        // Fake document geometry, all proportional so it holds at any dpi.
        let margin = W * 0.09
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))

        // Heading bar
        ctx.fill(CGRect(x: margin, y: H - margin - H * 0.035, width: W * 0.52, height: H * 0.022))

        // Body text lines
        var y = H - margin - H * 0.085
        for row in 0..<26 {
            let lineW = (W - 2 * margin) * (row % 7 == 6 ? 0.55 : Double.random(in: 0.86...0.99))
            ctx.setFillColor(CGColor(gray: 0.18, alpha: 0.88))
            ctx.fill(CGRect(x: margin, y: y, width: lineW, height: max(1, H * 0.0055)))
            y -= H * 0.019
            if row == 12 { y -= H * 0.02 }
        }

        // Colour reference bar — makes the Color tab's effect obvious.
        let swatches: [(Double, Double, Double)] = [
            (0.85, 0.15, 0.15), (0.95, 0.60, 0.10), (0.92, 0.88, 0.15),
            (0.20, 0.65, 0.25), (0.15, 0.45, 0.80), (0.45, 0.20, 0.65),
            (0.10, 0.10, 0.10), (0.55, 0.55, 0.55), (0.98, 0.98, 0.98)
        ]
        let barY = margin
        let barH = H * 0.07
        let swW = (W - 2 * margin) / Double(swatches.count)
        for (i, c) in swatches.enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: margin + Double(i) * swW, y: barY, width: swW, height: barH))
        }

        // Greyscale step wedge above the colour bar.
        let wedgeY = barY + barH + H * 0.012
        for i in 0..<11 {
            let g = Double(i) / 10.0
            ctx.setFillColor(CGColor(gray: g, alpha: 1))
            ctx.fill(CGRect(x: margin + Double(i) * (W - 2 * margin) / 11,
                            y: wedgeY, width: (W - 2 * margin) / 11, height: H * 0.03))
        }

        // Registration marks at the bed corners.
        ctx.setStrokeColor(CGColor(gray: 0.35, alpha: 1))
        ctx.setLineWidth(max(1, W * 0.0015))
        for (cx, cy) in [(margin * 0.45, margin * 0.45), (W - margin * 0.45, margin * 0.45),
                         (margin * 0.45, H - margin * 0.45), (W - margin * 0.45, H - margin * 0.45)] {
            ctx.strokeEllipse(in: CGRect(x: cx - W * 0.012, y: cy - W * 0.012,
                                         width: W * 0.024, height: W * 0.024))
        }

        guard var image = ctx.makeImage() else {
            throw ScanError.transferFailed("bitmap did not produce an image")
        }

        // Sensor noise — previews are noisier because they run the fast carriage pass.
        let noise = request.isPreview ? 0.030 : 0.012
        if let noisy = addNoise(to: image, amount: noise) { image = noisy }

        // Only the flatbed area actually requested was drawn, but keep bed
        // dimensions honest in case the caller cross-checks aspect ratio.
        _ = (bedW, bedH)
        return image
    }

    private static func addNoise(to image: CGImage, amount: Double) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data else { return nil }
        let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let magnitude = amount * 255
        // Sample sparsely: full per-pixel RNG on a 600 dpi page is needlessly slow.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = Double(Int((seed >> 33) & 0xFFFF)) / 65535.0 - 0.5
            let delta = Int(r * magnitude * 2)
            for c in 0..<3 {
                px[i + c] = UInt8(clamping: Int(px[i + c]) + delta)
            }
        }
        return ctx.makeImage()
    }
}
