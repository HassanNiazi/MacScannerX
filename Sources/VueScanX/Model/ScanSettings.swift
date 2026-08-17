import Foundation
import CoreGraphics

// MARK: - Enums mirroring VueScan's option vocabulary

enum ScanTask: String, CaseIterable, Identifiable, Codable {
    case scanToFile = "Scan to file"
    case copyToPrinter = "Copy to printer"
    case scanToEmail = "Scan to email"
    case profileScanner = "Profile scanner"
    var id: String { rawValue }
}

enum ScanSource: String, CaseIterable, Identifiable, Codable {
    case flatbed = "Flatbed"
    case feeder = "Feeder"
    case feederDuplex = "Feeder (duplex)"
    var id: String { rawValue }
}

/// VueScan calls this "Media" — it drives both the device colour mode and the
/// default tone/colour treatment applied downstream.
enum MediaType: String, CaseIterable, Identifiable, Codable {
    case colorPhoto = "Color photo"
    case grayscalePhoto = "Grayscale photo"
    case textDocument = "Text document"
    case lineArt = "Line art"
    case slideFilm = "Slide film"
    case bwNegative = "B/W negative"
    var id: String { rawValue }

    var isMonochrome: Bool { self == .grayscalePhoto || self == .lineArt }
    var isBilevel: Bool { self == .lineArt }
    var isNegative: Bool { self == .bwNegative }
}

enum BitDepth: String, CaseIterable, Identifiable, Codable {
    case bw1 = "1 bit B/W"
    case gray8 = "8 bit gray"
    case gray16 = "16 bit gray"
    case rgb24 = "24 bit RGB"
    case rgb48 = "48 bit RGB"
    var id: String { rawValue }

    var bitsPerChannel: Int {
        switch self {
        case .bw1: return 1
        case .gray8, .rgb24: return 8
        case .gray16, .rgb48: return 16
        }
    }
    var channels: Int {
        switch self {
        case .bw1, .gray8, .gray16: return 1
        case .rgb24, .rgb48: return 3
        }
    }
}

enum Rotation: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case right = "Right"
    case left = "Left"
    case oneEighty = "180°"
    var id: String { rawValue }

    var degrees: Int {
        switch self {
        case .none: return 0
        case .right: return -90
        case .left: return 90
        case .oneEighty: return 180
        }
    }
}

enum Units: String, CaseIterable, Identifiable, Codable {
    case mm = "mm"
    case inch = "in"
    case pixels = "px"
    var id: String { rawValue }
}

enum CropPreset: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto"
    case maximum = "Maximum"
    case manual = "Manual"
    case a4 = "A4"
    case a5 = "A5"
    case letter = "Letter"
    case legal = "Legal"
    case photo4x6 = "4x6 in"
    case photo5x7 = "5x7 in"
    case photo8x10 = "8x10 in"
    var id: String { rawValue }

    /// Size in millimetres, or nil for the non-fixed presets.
    var millimetres: CGSize? {
        switch self {
        case .auto, .maximum, .manual: return nil
        case .a4: return CGSize(width: 210, height: 297)
        case .a5: return CGSize(width: 148, height: 210)
        case .letter: return CGSize(width: 215.9, height: 279.4)
        case .legal: return CGSize(width: 215.9, height: 355.6)
        case .photo4x6: return CGSize(width: 101.6, height: 152.4)
        case .photo5x7: return CGSize(width: 127, height: 177.8)
        case .photo8x10: return CGSize(width: 203.2, height: 254)
        }
    }
}

enum Strength: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case light = "Light"
    case medium = "Medium"
    case heavy = "Heavy"
    var id: String { rawValue }

    var scalar: Double {
        switch self {
        case .none: return 0
        case .light: return 0.33
        case .medium: return 0.66
        case .heavy: return 1.0
        }
    }
}

enum ColorBalance: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case neutral = "Neutral"
    case autoLevels = "Auto levels"
    case autoWhite = "Auto white balance"
    case landscape = "Landscape"
    case manual = "Manual"
    var id: String { rawValue }
}

enum OutputColorSpace: String, CaseIterable, Identifiable, Codable {
    case srgb = "sRGB"
    case adobeRGB = "Adobe RGB"
    case displayP3 = "Display P3"
    case grayGamma22 = "Gray gamma 2.2"
    var id: String { rawValue }
}

enum TIFFCompression: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case lzw = "LZW"
    case packbits = "Packbits"
    var id: String { rawValue }
}

enum PDFPaperSize: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto"
    case a4 = "A4"
    case letter = "Letter"
    case legal = "Legal"
    var id: String { rawValue }

    /// Size in PDF points (1/72 in).
    var points: CGSize? {
        switch self {
        case .auto: return nil
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .letter: return CGSize(width: 612, height: 792)
        case .legal: return CGSize(width: 612, height: 1008)
        }
    }
}

enum BatchMode: String, CaseIterable, Identifiable, Codable {
    case off = "Off"
    case list = "List"
    case all = "All"
    var id: String { rawValue }
}

// MARK: - Settings container

/// Every user-adjustable knob, grouped the way VueScan groups them in its tabs.
/// Persisted verbatim to `~/Library/Application Support/VueScanX/settings.json`.
struct ScanSettings: Codable, Equatable {

    // ---- Input ------------------------------------------------------------
    var task: ScanTask = .scanToFile
    var deviceIdentifier: String? = nil
    var source: ScanSource = .flatbed
    var media: MediaType = .colorPhoto
    var bitDepth: BitDepth = .rgb24
    var scanResolution: Int = 300
    var previewResolution: Int = 75
    var rotation: Rotation = .none
    var mirror: Bool = false
    var autoSkew: Bool = false
    var autoRotate: Bool = false
    var numberOfSamples: Int = 1
    var batchMode: BatchMode = .off
    var batchCount: Int = 1
    var autoEjectAfterScan: Bool = false

    // ---- Crop -------------------------------------------------------------
    var cropPreset: CropPreset = .maximum
    var units: Units = .mm
    /// Crop rectangle in millimetres, origin at the top-left of the scan bed.
    var cropOriginMM: CGPoint = .zero
    var cropSizeMM: CGSize = CGSize(width: 215.9, height: 297)
    var lockAspectRatio: Bool = false
    var aspectRatio: Double = 1.5
    var autoCropBufferPercent: Double = 0
    var borderPercent: Double = 0

    // ---- Filter -----------------------------------------------------------
    var restoreColors: Bool = false
    var restoreFading: Bool = false
    var descreen: Bool = false
    var descreenDPI: Int = 300
    var grainReduction: Strength = .none
    var sharpen: Strength = .light
    var bilevelThreshold: Double = 0.5

    // ---- Color ------------------------------------------------------------
    var colorBalance: ColorBalance = .autoLevels
    var whitePointPercent: Double = 1.0
    var blackPointPercent: Double = 0.5
    var curveLow: Double = 0.25
    var curveHigh: Double = 0.75
    var brightness: Double = 1.0
    var redBrightness: Double = 1.0
    var greenBrightness: Double = 1.0
    var blueBrightness: Double = 1.0
    var saturation: Double = 1.0
    var outputColorSpace: OutputColorSpace = .srgb
    var invert: Bool = false

    // ---- Output -----------------------------------------------------------
    var outputFolder: URL = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    var fileNameTemplate: String = "scan+.jpg"
    var writeJPEG: Bool = true
    var writeTIFF: Bool = false
    var writePDF: Bool = false
    var writePNG: Bool = false
    var writeOCRText: Bool = false
    var jpegQuality: Double = 0.9
    var tiffCompression: TIFFCompression = .lzw
    var pdfMultiPage: Bool = true
    var pdfPaperSize: PDFPaperSize = .auto
    var pdfSearchable: Bool = false
    var ocrLanguage: String = "en-US"

    // ---- Prefs ------------------------------------------------------------
    var showAdvancedOptions: Bool = true
    var previewAfterScan: Bool = true
    var revealInFinderAfterSave: Bool = false
    var warmUpDevice: Bool = true

    // ---- Derived ----------------------------------------------------------

    /// Crop rect in millimetres, honouring the fixed-size presets.
    var effectiveCropMM: CGRect {
        if let fixed = cropPreset.millimetres {
            let size = aspectAdjusted(fixed)
            return CGRect(origin: cropOriginMM, size: size)
        }
        return CGRect(origin: cropOriginMM, size: cropSizeMM)
    }

    private func aspectAdjusted(_ size: CGSize) -> CGSize {
        guard lockAspectRatio, aspectRatio > 0 else { return size }
        return CGSize(width: size.height * aspectRatio, height: size.height)
    }

    var isPreviewOnlyDevice: Bool { deviceIdentifier == nil }
}

// MARK: - Persistence

extension ScanSettings {
    static var storeURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VueScanX", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }

    static func load() -> ScanSettings {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(ScanSettings.self, from: data)
        else { return ScanSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

// MARK: - Unit helpers

enum UnitConvert {
    static let mmPerInch = 25.4

    static func mmToPixels(_ mm: Double, dpi: Int) -> Double {
        mm / mmPerInch * Double(dpi)
    }
    static func pixelsToMM(_ px: Double, dpi: Int) -> Double {
        px / Double(dpi) * mmPerInch
    }
    static func display(_ mm: Double, units: Units, dpi: Int) -> Double {
        switch units {
        case .mm: return mm
        case .inch: return mm / mmPerInch
        case .pixels: return mmToPixels(mm, dpi: dpi)
        }
    }
    static func toMM(_ value: Double, units: Units, dpi: Int) -> Double {
        switch units {
        case .mm: return value
        case .inch: return value * mmPerInch
        case .pixels: return pixelsToMM(value, dpi: dpi)
        }
    }
}
