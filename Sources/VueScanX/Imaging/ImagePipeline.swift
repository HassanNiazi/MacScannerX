import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Accelerate

/// Applies the Crop / Filter / Color tab settings to a raw scan.
///
/// Order matters and mirrors VueScan's own pipeline:
///   geometry (crop → rotate → mirror) → restore → descreen → grain → tone/colour
///   → sharpen (always last, so it does not amplify noise the earlier stages removed)
///   → bilevel threshold, if the media is line art.
struct ImagePipeline {

    static let context: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any
        ])
    }()

    let settings: ScanSettings
    /// dpi of the incoming raw image, needed to translate mm crop values.
    let sourceDPI: Int
    /// True when the crop was already performed by the scanner hardware.
    let cropAlreadyApplied: Bool

    func process(_ input: CGImage) throws -> CGImage {
        var image = CIImage(cgImage: input)

        image = applyGeometry(image, pixelSize: CGSize(width: input.width, height: input.height))
        image = applyRestore(image)
        image = applyDescreen(image)
        image = applyGrainReduction(image)
        image = applyTone(image)
        image = applyColorCast(image)
        image = applyMedia(image)
        image = applySharpen(image)
        image = applyBilevel(image)

        let rect = image.extent.isInfinite
            ? CGRect(x: 0, y: 0, width: input.width, height: input.height)
            : image.extent

        guard let out = Self.context.createCGImage(image, from: rect,
                                                   format: .RGBA8,
                                                   colorSpace: outputColorSpace()) else {
            throw ScanError.transferFailed("image pipeline produced no output")
        }
        return out
    }

    // MARK: Geometry

    private func applyGeometry(_ image: CIImage, pixelSize: CGSize) -> CIImage {
        var out = image

        if !cropAlreadyApplied, settings.cropPreset != .maximum {
            let crop = settings.effectiveCropMM
            let x = UnitConvert.mmToPixels(crop.origin.x, dpi: sourceDPI)
            let w = UnitConvert.mmToPixels(crop.width, dpi: sourceDPI)
            let h = UnitConvert.mmToPixels(crop.height, dpi: sourceDPI)
            // Crop origin is top-left in the UI; CIImage is bottom-left.
            let yTop = UnitConvert.mmToPixels(crop.origin.y, dpi: sourceDPI)
            let y = max(0, pixelSize.height - yTop - h)
            let rect = CGRect(x: x, y: y, width: w, height: h)
                .intersection(CGRect(origin: .zero, size: pixelSize))
            if !rect.isNull, rect.width >= 1, rect.height >= 1 {
                out = out.cropped(to: rect)
                out = out.transformed(by: CGAffineTransform(translationX: -rect.origin.x,
                                                            y: -rect.origin.y))
            }
        }

        if settings.borderPercent > 0 {
            let e = out.extent
            let inset = min(e.width, e.height) * settings.borderPercent / 100
            let r = e.insetBy(dx: inset, dy: inset)
            if r.width >= 1, r.height >= 1 {
                out = out.cropped(to: r)
                    .transformed(by: CGAffineTransform(translationX: -r.origin.x, y: -r.origin.y))
            }
        }

        if settings.mirror {
            let e = out.extent
            out = out.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .concatenating(CGAffineTransform(translationX: e.width, y: 0)))
        }

        if settings.rotation != .none {
            let radians = CGFloat(settings.rotation.degrees) * .pi / 180
            let e = out.extent
            var t = CGAffineTransform(rotationAngle: radians)
            let rotated = e.applying(t)
            t = t.concatenating(CGAffineTransform(translationX: -rotated.origin.x,
                                                  y: -rotated.origin.y))
            out = out.transformed(by: t)
        }

        return out
    }

    // MARK: Restore

    private func applyRestore(_ image: CIImage) -> CIImage {
        var out = image
        if settings.restoreFading {
            // Faded originals lose contrast first; stretch before touching hue.
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.contrast = 1.18
            f.brightness = -0.02
            f.saturation = 1.0
            out = f.outputImage ?? out
        }
        if settings.restoreColors {
            let v = CIFilter.vibrance()
            v.inputImage = out
            v.amount = 0.6
            out = v.outputImage ?? out

            // Old prints skew warm; pull the cast back toward neutral.
            if let stats = Self.averageColor(out) {
                let mean = (stats.r + stats.g + stats.b) / 3
                guard stats.r > 0.001, stats.g > 0.001, stats.b > 0.001 else { return out }
                let m = CIFilter.colorMatrix()
                m.inputImage = out
                m.rVector = CIVector(x: CGFloat(mean / stats.r), y: 0, z: 0, w: 0)
                m.gVector = CIVector(x: 0, y: CGFloat(mean / stats.g), z: 0, w: 0)
                m.bVector = CIVector(x: 0, y: 0, z: CGFloat(mean / stats.b), w: 0)
                m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
                out = m.outputImage ?? out
            }
        }
        return out
    }

    // MARK: Descreen

    private func applyDescreen(_ image: CIImage) -> CIImage {
        guard settings.descreen else { return image }
        // Halftone dots sit at the screen frequency; a blur radius of roughly
        // half the dot pitch (in scan pixels) knocks them out without eating
        // real detail, then a light unsharp restores edge crispness.
        let pitchPixels = Double(sourceDPI) / Double(max(50, settings.descreenDPI))
        let radius = max(0.6, min(4.0, pitchPixels * 0.75))

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(radius)
        guard let blurred = blur.outputImage?.cropped(to: image.extent) else { return image }

        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = blurred
        unsharp.radius = Float(radius * 1.5)
        unsharp.intensity = 0.35
        return unsharp.outputImage ?? blurred
    }

    // MARK: Grain

    private func applyGrainReduction(_ image: CIImage) -> CIImage {
        guard settings.grainReduction != .none else { return image }
        let s = settings.grainReduction.scalar
        let f = CIFilter.noiseReduction()
        f.inputImage = image
        f.noiseLevel = Float(0.008 + 0.045 * s)
        f.sharpness = Float(0.8 - 0.3 * s)
        return f.outputImage ?? image
    }

    // MARK: Tone / levels / curves

    private func applyTone(_ image: CIImage) -> CIImage {
        var black = settings.blackPointPercent / 100
        var white = 1.0 - settings.whitePointPercent / 100

        switch settings.colorBalance {
        case .none:
            return applyBrightnessOnly(image)
        case .neutral:
            black = 0; white = 1
        case .autoLevels, .autoWhite, .landscape:
            if let (lo, hi) = Self.percentileLevels(image,
                                                    lowPercent: settings.blackPointPercent,
                                                    highPercent: settings.whitePointPercent) {
                black = lo; white = hi
            }
        case .manual:
            break
        }

        if white <= black { white = min(1.0, black + 0.01) }

        let curve = CIFilter.toneCurve()
        curve.inputImage = image
        // Anchor endpoints at the measured levels, then bend the midtones with
        // the two curve controls so the Color tab's sliders do something real.
        curve.point0 = CGPoint(x: black, y: 0)
        curve.point1 = CGPoint(x: black + (white - black) * 0.25,
                               y: clamp(settings.curveLow))
        curve.point2 = CGPoint(x: black + (white - black) * 0.5, y: 0.5)
        curve.point3 = CGPoint(x: black + (white - black) * 0.75,
                               y: clamp(settings.curveHigh))
        curve.point4 = CGPoint(x: white, y: 1)
        var out = curve.outputImage ?? image

        if settings.colorBalance == .landscape {
            let v = CIFilter.vibrance()
            v.inputImage = out
            v.amount = 0.35
            out = v.outputImage ?? out
        }
        if settings.colorBalance == .autoWhite, let stats = Self.averageColor(out) {
            let mean = (stats.r + stats.g + stats.b) / 3
            if stats.r > 0.001, stats.g > 0.001, stats.b > 0.001 {
                let m = CIFilter.colorMatrix()
                m.inputImage = out
                m.rVector = CIVector(x: CGFloat(mean / stats.r), y: 0, z: 0, w: 0)
                m.gVector = CIVector(x: 0, y: CGFloat(mean / stats.g), z: 0, w: 0)
                m.bVector = CIVector(x: 0, y: 0, z: CGFloat(mean / stats.b), w: 0)
                m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
                out = m.outputImage ?? out
            }
        }
        return applyBrightnessOnly(out)
    }

    private func applyBrightnessOnly(_ image: CIImage) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = image
        // VueScan's Brightness is a multiplier around 1.0; CIColorControls wants
        // an additive offset, so convert through a gamma-ish log mapping.
        f.brightness = Float((settings.brightness - 1.0) * 0.5)
        f.saturation = Float(settings.saturation)
        f.contrast = 1.0
        return f.outputImage ?? image
    }

    // MARK: Per-channel gain + invert

    private func applyColorCast(_ image: CIImage) -> CIImage {
        var out = image
        let r = settings.redBrightness, g = settings.greenBrightness, b = settings.blueBrightness
        if abs(r - 1) > 0.001 || abs(g - 1) > 0.001 || abs(b - 1) > 0.001 {
            let m = CIFilter.colorMatrix()
            m.inputImage = out
            m.rVector = CIVector(x: CGFloat(r), y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: CGFloat(g), z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: CGFloat(b), w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            out = m.outputImage ?? out
        }
        if settings.invert || settings.media.isNegative {
            let f = CIFilter.colorInvert()
            f.inputImage = out
            out = f.outputImage ?? out
        }
        return out
    }

    // MARK: Media-driven colour mode

    private func applyMedia(_ image: CIImage) -> CIImage {
        guard settings.media.isMonochrome || settings.bitDepth.channels == 1 else { return image }
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        // Rec. 709 luma, applied to all three channels so downstream filters
        // and the on-screen preview agree.
        let lr: CGFloat = 0.2126, lg: CGFloat = 0.7152, lb: CGFloat = 0.0722
        f.rVector = CIVector(x: lr, y: lg, z: lb, w: 0)
        f.gVector = CIVector(x: lr, y: lg, z: lb, w: 0)
        f.bVector = CIVector(x: lr, y: lg, z: lb, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage ?? image
    }

    // MARK: Sharpen

    private func applySharpen(_ image: CIImage) -> CIImage {
        guard settings.sharpen != .none else { return image }
        let s = settings.sharpen.scalar
        let f = CIFilter.unsharpMask()
        f.inputImage = image
        f.radius = Float(1.2 + 1.8 * s)
        f.intensity = Float(0.25 + 0.75 * s)
        return f.outputImage ?? image
    }

    // MARK: Bilevel

    private func applyBilevel(_ image: CIImage) -> CIImage {
        guard settings.media.isBilevel || settings.bitDepth == .bw1 else { return image }
        let f = CIFilter.colorThreshold()
        f.inputImage = image
        f.threshold = Float(settings.bilevelThreshold)
        return f.outputImage ?? image
    }

    // MARK: Colour space

    private func outputColorSpace() -> CGColorSpace {
        switch settings.outputColorSpace {
        case .srgb:         return CGColorSpace(name: CGColorSpace.sRGB)!
        case .adobeRGB:     return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        case .displayP3:    return CGColorSpace(name: CGColorSpace.displayP3)!
        case .grayGamma22:  return CGColorSpace(name: CGColorSpace.linearGray)!
        }
    }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    // MARK: Statistics

    struct RGBStats { let r: Double; let g: Double; let b: Double }

    /// Mean colour of the image, computed by Core Image on the GPU.
    static func averageColor(_ image: CIImage) -> RGBStats? {
        guard !image.extent.isInfinite, image.extent.width >= 1 else { return nil }
        let f = CIFilter.areaAverage()
        f.inputImage = image
        f.extent = image.extent
        guard let out = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return RGBStats(r: Double(px[0]) / 255, g: Double(px[1]) / 255, b: Double(px[2]) / 255)
    }

    /// Black/white clipping points, taken from the luminance histogram at the
    /// requested percentiles — this is what "Auto levels" actually means.
    static func percentileLevels(_ image: CIImage,
                                 lowPercent: Double,
                                 highPercent: Double) -> (Double, Double)? {
        guard !image.extent.isInfinite, image.extent.width >= 1 else { return nil }
        let bins = 256
        let f = CIFilter.areaHistogram()
        f.inputImage = image
        f.extent = image.extent
        f.count = bins
        f.scale = 1
        guard let out = f.outputImage else { return nil }

        var raw = [Float](repeating: 0, count: bins * 4)
        context.render(out, toBitmap: &raw, rowBytes: bins * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
                       format: .RGBAf, colorSpace: nil)

        var luma = [Double](repeating: 0, count: bins)
        var total = 0.0
        for i in 0..<bins {
            let v = Double(raw[i * 4]) + Double(raw[i * 4 + 1]) + Double(raw[i * 4 + 2])
            luma[i] = v
            total += v
        }
        guard total > 0 else { return nil }

        let lowTarget = total * (lowPercent / 100)
        let highTarget = total * (1 - highPercent / 100)

        var running = 0.0
        var lo = 0, hi = bins - 1
        for i in 0..<bins {
            running += luma[i]
            if running >= lowTarget { lo = i; break }
        }
        running = 0
        for i in 0..<bins {
            running += luma[i]
            if running >= highTarget { hi = i; break }
        }
        if hi <= lo { hi = min(bins - 1, lo + 1) }
        return (Double(lo) / Double(bins - 1), Double(hi) / Double(bins - 1))
    }
}
