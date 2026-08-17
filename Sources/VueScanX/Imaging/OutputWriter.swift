import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import AppKit

/// Writes processed pages out in every format the Output tab has ticked.
struct OutputWriter {

    let settings: ScanSettings

    struct Result {
        var files: [URL] = []
        var ocrText: String?
    }

    // MARK: File naming

    /// VueScan's `+` token means "auto-incrementing serial". `scan+.jpg` →
    /// `scan0001.jpg`, then `scan0002.jpg`. Multiple `+` widen the field.
    func resolveName(template: String, ext: String, in folder: URL) -> URL {
        var base = template
        if let dot = base.lastIndex(of: ".") { base = String(base[base.startIndex..<dot]) }

        let plusRun = base.reduce(into: (best: 0, run: 0)) { acc, ch in
            if ch == "+" { acc.run += 1; acc.best = max(acc.best, acc.run) } else { acc.run = 0 }
        }.best

        // Date tokens, matching VueScan's strftime-ish substitutions.
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        base = base.replacingOccurrences(of: "%Y-%m-%d", with: fmt.string(from: now))
        fmt.dateFormat = "yyyyMMdd"
        base = base.replacingOccurrences(of: "%date", with: fmt.string(from: now))
        fmt.dateFormat = "HHmmss"
        base = base.replacingOccurrences(of: "%time", with: fmt.string(from: now))

        guard plusRun > 0 else {
            return uniqued(folder.appendingPathComponent(base).appendingPathExtension(ext))
        }

        let pluses = String(repeating: "+", count: plusRun)
        let width = max(4, plusRun)
        for n in 1...99_999 {
            let serial = String(format: "%0\(width)d", n)
            let name = base.replacingOccurrences(of: pluses, with: serial)
            let url = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return uniqued(folder.appendingPathComponent(base).appendingPathExtension(ext))
    }

    private func uniqued(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        for n in 1...9999 {
            let candidate = URL(fileURLWithPath: "\(base.path)-\(n)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    // MARK: Write

    func write(pages: [ScanPage], processed: [CGImage]) async throws -> Result {
        guard !processed.isEmpty else { return Result() }
        try FileManager.default.createDirectory(at: settings.outputFolder,
                                                withIntermediateDirectories: true)
        var result = Result()

        var ocrPerPage: [String] = []
        if settings.writeOCRText || settings.pdfSearchable {
            for image in processed {
                ocrPerPage.append((try? await recognizeText(in: image)) ?? "")
            }
            result.ocrText = ocrPerPage.joined(separator: "\n\n\u{000C}\n\n")
        }

        if settings.writeJPEG {
            result.files += try writeRaster(processed, type: .jpeg, ext: "jpg", pages: pages)
        }
        if settings.writePNG {
            result.files += try writeRaster(processed, type: .png, ext: "png", pages: pages)
        }
        if settings.writeTIFF {
            result.files += try writeRaster(processed, type: .tiff, ext: "tif", pages: pages)
        }
        if settings.writePDF {
            result.files.append(try writePDF(processed, pages: pages,
                                             text: settings.pdfSearchable ? ocrPerPage : nil))
        }
        if settings.writeOCRText, let text = result.ocrText {
            let url = resolveName(template: settings.fileNameTemplate, ext: "txt",
                                  in: settings.outputFolder)
            try text.write(to: url, atomically: true, encoding: .utf8)
            result.files.append(url)
        }
        return result
    }

    // MARK: Raster

    private func writeRaster(_ images: [CGImage], type: UTType, ext: String,
                             pages: [ScanPage]) throws -> [URL] {
        // Multi-page TIFF when several pages came off a feeder; one file each otherwise.
        if type == .tiff, images.count > 1 {
            let url = resolveName(template: settings.fileNameTemplate, ext: ext,
                                  in: settings.outputFolder)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString,
                                                             images.count, nil) else {
                throw ScanError.transferFailed("could not create \(url.lastPathComponent)")
            }
            for (i, image) in images.enumerated() {
                CGImageDestinationAddImage(dest, image, properties(for: type, dpi: pages[safe: i]?.dpi) as CFDictionary)
            }
            guard CGImageDestinationFinalize(dest) else {
                throw ScanError.transferFailed("could not finalise \(url.lastPathComponent)")
            }
            return [url]
        }

        var urls: [URL] = []
        for (i, image) in images.enumerated() {
            let url = resolveName(template: settings.fileNameTemplate, ext: ext,
                                  in: settings.outputFolder)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw ScanError.transferFailed("could not create \(url.lastPathComponent)")
            }
            CGImageDestinationAddImage(dest, image, properties(for: type, dpi: pages[safe: i]?.dpi) as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw ScanError.transferFailed("could not finalise \(url.lastPathComponent)")
            }
            urls.append(url)
        }
        return urls
    }

    private func properties(for type: UTType, dpi: Int?) -> [CFString: Any] {
        var props: [CFString: Any] = [:]
        let resolution = dpi ?? settings.scanResolution
        props[kCGImagePropertyDPIWidth] = resolution
        props[kCGImagePropertyDPIHeight] = resolution

        if type == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = settings.jpegQuality
            props[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFXResolution: resolution,
                kCGImagePropertyTIFFYResolution: resolution,
                kCGImagePropertyTIFFSoftware: "VueScanX"
            ]
        }
        if type == .tiff {
            let compression: Int
            switch settings.tiffCompression {
            case .none:     compression = 1
            case .lzw:      compression = 5
            case .packbits: compression = 32773
            }
            props[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFCompression: compression,
                kCGImagePropertyTIFFXResolution: resolution,
                kCGImagePropertyTIFFYResolution: resolution,
                kCGImagePropertyTIFFSoftware: "VueScanX"
            ]
        }
        return props
    }

    // MARK: PDF

    private func writePDF(_ images: [CGImage], pages: [ScanPage], text: [String]?) throws -> URL {
        let url = resolveName(template: settings.fileNameTemplate, ext: "pdf",
                              in: settings.outputFolder)

        var info: [CFString: Any] = [
            kCGPDFContextCreator: "VueScanX",
            kCGPDFContextTitle: url.deletingPathExtension().lastPathComponent
        ]
        if let text, !text.isEmpty {
            info[kCGPDFContextKeywords] = text.joined(separator: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { $0.count > 3 }
                .prefix(200)
                .joined(separator: " ")
        }

        let firstBox = pageRect(for: images[0], dpi: pages.first?.dpi)
        var mediaBox = firstBox
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ScanError.transferFailed("could not create \(url.lastPathComponent)")
        }

        let toWrite = settings.pdfMultiPage ? images : Array(images.prefix(1))
        for (i, image) in toWrite.enumerated() {
            var box = pageRect(for: image, dpi: pages[safe: i]?.dpi)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            if let text, let pageText = text[safe: i], !pageText.isEmpty {
                drawInvisibleText(pageText, in: box, context: ctx)
            }
            ctx.endPage()
        }
        ctx.closePDF()
        return url
    }

    private func pageRect(for image: CGImage, dpi: Int?) -> CGRect {
        if let fixed = settings.pdfPaperSize.points {
            return CGRect(origin: .zero, size: fixed)
        }
        let resolution = Double(dpi ?? settings.scanResolution)
        // 72 pt per inch: pixels / dpi * 72.
        return CGRect(x: 0, y: 0,
                      width: Double(image.width) / resolution * 72,
                      height: Double(image.height) / resolution * 72)
    }

    /// Text rendering mode 3 = invisible. Gives a selectable/searchable layer
    /// over the scanned bitmap without altering how the page looks.
    private func drawInvisibleText(_ text: String, in box: CGRect, context ctx: CGContext) {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        let fontSize = max(6.0, box.height / Double(max(lines.count, 1)) * 0.7)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let step = box.height / Double(lines.count + 1)
        for (i, line) in lines.enumerated() {
            let y = box.height - step * Double(i + 1)
            let attributed = NSAttributedString(string: line, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: box.width * 0.08, y: y)
            CTLineDraw(ctLine, ctx)
        }
        ctx.restoreGState()
    }

    // MARK: OCR

    func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { req, error in
                if let error { cont.resume(throwing: error); return }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = [settings.ocrLanguage]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) }
            catch { cont.resume(throwing: error) }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
