import Foundation
import SwiftUI
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `MacScannerX --selftest [outputDir]` drives the whole non-interactive path —
/// simulated acquisition, the Core Image pipeline, and every output format —
/// then renders the real UI offscreen. Used to verify the app end to end on a
/// machine with no scanner attached and no screen-recording permission.
@MainActor
enum SelfTest {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    static var isDeviceDumpRequested: Bool {
        CommandLine.arguments.contains("--devices")
    }

    static var isTestScanRequested: Bool {
        CommandLine.arguments.contains("--testscan")
    }

    /// `MacScannerX --testscan [dpi] [out.jpg]` — acquire one page from the first
    /// real scanner found, run it through the full processing pipeline, and
    /// write it out. Verifies the hardware path end to end without the GUI.
    static func testScan() async -> Int32 {
        let args = CommandLine.arguments
        let i = args.firstIndex(of: "--testscan")!
        let dpi = (args.count > i + 1 ? Int(args[i + 1]) : nil) ?? 150
        let outPath = args.count > i + 2 ? args[i + 2] : "/tmp/macscannerx-testscan.jpg"

        let ledm = LEDMBackend()
        var found: [ScannerDeviceInfo] = []
        ledm.startDiscovery { found = $0 }
        for _ in 0..<40 where found.isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        ledm.stopDiscovery()

        guard let device = found.first else {
            print("No LEDM scanner found.")
            return 1
        }
        print("Scanning on \(device.name) at \(dpi) dpi…")

        let bed = device.bedSizeMM ?? CGSize(width: 215.9, height: 297)
        let request = ScanRequest(source: .flatbed, resolutionDPI: dpi,
                                  areaMM: CGRect(origin: .zero, size: bed),
                                  bitDepth: .rgb24, isPreview: false)
        do {
            let pages = try await ledm.scan(deviceID: device.id, request: request) { fraction, stage in
                print(String(format: "  %3.0f%%  %@", fraction * 100, stage))
            }
            guard let page = pages.first else { print("no pages"); return 1 }
            print("Raw page: \(page.image.width)×\(page.image.height) px")

            var settings = ScanSettings()
            settings.scanResolution = dpi
            settings.cropPreset = .maximum
            settings.colorBalance = .autoLevels
            settings.sharpen = .light
            let processed = try ImagePipeline(settings: settings, sourceDPI: dpi,
                                              cropAlreadyApplied: true).process(page.image)
            print("Processed:  \(processed.width)×\(processed.height) px")

            let url = URL(fileURLWithPath: outPath)
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                print("could not create \(outPath)")
                return 1
            }
            CGImageDestinationAddImage(dest, processed,
                                       [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { print("write failed"); return 1 }
            print("Wrote \(outPath)")
            print("\nPASS — real scan completed")
            return 0
        } catch {
            print("FAIL — \(error.localizedDescription)")
            return 1
        }
    }

    /// `MacScannerX --devices [seconds]` — browse for scanners, print what each
    /// backend sees, and probe the first real one for its true capabilities.
    /// The fastest way to tell whether a scanner problem is discovery or
    /// acquisition.
    static func dumpDevices() async -> Int32 {
        let seconds = deviceDumpSeconds()
        let ica = ImageCaptureBackend()
        let escl = ESCLBackend()
        let ledm = LEDMBackend()

        var icaFound: [ScannerDeviceInfo] = []
        var esclFound: [ScannerDeviceInfo] = []
        var ledmFound: [ScannerDeviceInfo] = []

        print("Browsing for scanners for \(Int(seconds))s…\n")
        ica.startDiscovery { icaFound = $0 }
        escl.startDiscovery { esclFound = $0 }
        ledm.startDiscovery { ledmFound = $0 }

        // The app's own run loop is already pumping, so just wait.
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        ica.stopDiscovery()
        escl.stopDiscovery()
        ledm.stopDiscovery()

        report("HP LEDM over USB", ledmFound)
        report("ImageCaptureCore", icaFound)
        report("eSCL / AirScan", esclFound)

        let real = ledmFound + icaFound + esclFound
        guard let target = real.first else {
            print("No scanners found.")
            print("""

                  An HP all-in-one on USB is reached over LEDM. If it is missing:
                    • confirm it is powered on and not mid-print
                    • quit HP Smart / HP Easy Scan — they hold the USB interface open
                    • over Wi-Fi, allow this app under Privacy & Security › Local Network
                  """)
            return 1
        }

        print("Probing \(target.name)…")
        let backend: ScannerBackend
        if target.id.hasPrefix("ledm:")      { backend = ledm }
        else if target.id.hasPrefix("escl:") { backend = escl }
        else                                 { backend = ica }
        do {
            let info = try await backend.probe(deviceID: target.id)
            print("  bed          \(info.bedSizeMM.map(sizeDescription) ?? "unknown")")
            print("  sources      \(info.supportedSources.map(\.rawValue).joined(separator: ", "))")
            print("  resolutions  \(info.supportedResolutions.map(String.init).joined(separator: ", ")) dpi")
            print("\nPASS — scanner reachable")
            return 0
        } catch {
            print("  probe failed: \(error.localizedDescription)")
            return 1
        }
    }

    private static func deviceDumpSeconds() -> TimeInterval {
        guard let i = CommandLine.arguments.firstIndex(of: "--devices"),
              CommandLine.arguments.count > i + 1,
              let n = Double(CommandLine.arguments[i + 1]) else { return 8 }
        return min(max(n, 1), 120)
    }

    private static func report(_ title: String, _ devices: [ScannerDeviceInfo]) {
        print("\(title): \(devices.isEmpty ? "nothing found" : "\(devices.count) device(s)")")
        for d in devices {
            print("  • \(d.name)")
            print("      id         \(d.id)")
            print("      transport  \(d.transport.rawValue)")
            print("      model      \(d.model)")
            print("      bed        \(d.bedSizeMM.map(sizeDescription) ?? "unknown")")
            print("      sources    \(d.supportedSources.map(\.rawValue).joined(separator: ", "))")
            print("      dpi        \(d.supportedResolutions.map(String.init).joined(separator: ", "))")
        }
        print("")
    }

    static func run() async -> Int32 {
        let outDir = customOutputDirectory() ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScannerX-selftest", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var failures = 0
        print("MacScannerX self-test")
        print("output: \(outDir.path)\n")

        failures += await checkAcquisition()
        failures += await checkPipeline()
        failures += await checkNaming(in: outDir)
        failures += await checkOutputFormats(in: outDir)
        failures += checkAutoCrop()
        failures += checkESCLRequestXML()
        failures += checkCapabilitiesParse()
        failures += await checkUIRender(in: outDir)

        print("")
        if failures == 0 {
            print("PASS — all checks green")
        } else {
            print("FAIL — \(failures) check\(failures == 1 ? "" : "s") failed")
        }
        return failures == 0 ? 0 : 1
    }

    private static func customOutputDirectory() -> URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "--selftest"),
              CommandLine.arguments.count > i + 1 else { return nil }
        let candidate = CommandLine.arguments[i + 1]
        guard !candidate.hasPrefix("-") else { return nil }
        return URL(fileURLWithPath: candidate)
    }

    // MARK: Checks

    private static func checkAcquisition() async -> Int {
        let sim = SimulatedBackend()
        let request = ScanRequest(source: .flatbed, resolutionDPI: 150,
                                  areaMM: CGRect(x: 0, y: 0, width: 215.9, height: 297),
                                  bitDepth: .rgb24, isPreview: false)
        do {
            let pages = try await sim.scan(deviceID: SimulatedBackend.deviceID,
                                           request: request) { _, _ in }
            guard let page = pages.first else { return fail("acquisition", "no pages returned") }
            // 215.9 mm at 150 dpi = 1275 px; allow rounding slack.
            let expectedW = Int((215.9 / 25.4 * 150).rounded())
            guard abs(page.image.width - expectedW) <= 2 else {
                return fail("acquisition", "width \(page.image.width), expected ≈\(expectedW)")
            }
            return pass("acquisition", "\(page.image.width)×\(page.image.height) px at \(page.dpi) dpi")
        } catch {
            return fail("acquisition", error.localizedDescription)
        }
    }

    private static func checkPipeline() async -> Int {
        var settings = ScanSettings()
        settings.scanResolution = 150
        settings.cropPreset = .manual
        settings.cropOriginMM = CGPoint(x: 20, y: 30)
        settings.cropSizeMM = CGSize(width: 100, height: 120)
        settings.rotation = .right
        settings.mirror = true
        settings.restoreColors = true
        settings.restoreFading = true
        settings.descreen = true
        settings.grainReduction = .medium
        settings.sharpen = .heavy
        settings.colorBalance = .autoLevels
        settings.saturation = 1.2
        settings.redBrightness = 1.1

        let request = ScanRequest(source: .flatbed, resolutionDPI: 150,
                                  areaMM: CGRect(x: 0, y: 0, width: 215.9, height: 297),
                                  bitDepth: .rgb24, isPreview: false)
        do {
            let raw = try SimulatedBackend.render(request: request)
            let pipeline = ImagePipeline(settings: settings, sourceDPI: 150, cropAlreadyApplied: false)
            let out = try pipeline.process(raw)

            // 100×120 mm cropped, then rotated 90° → 120×100 mm of pixels.
            let expectedW = Int((120.0 / 25.4 * 150).rounded())
            let expectedH = Int((100.0 / 25.4 * 150).rounded())
            guard abs(out.width - expectedW) <= 3, abs(out.height - expectedH) <= 3 else {
                return fail("pipeline", "got \(out.width)×\(out.height), expected ≈\(expectedW)×\(expectedH)")
            }
            var n = pass("pipeline crop+rotate", "\(out.width)×\(out.height) px")

            // Bilevel path must actually collapse to two levels.
            var bw = ScanSettings()
            bw.media = .lineArt
            bw.bitDepth = .bw1
            bw.cropPreset = .maximum
            bw.sharpen = .none
            let mono = try ImagePipeline(settings: bw, sourceDPI: 150, cropAlreadyApplied: true).process(raw)
            let levels = distinctLuminanceCount(mono)
            guard levels <= 8 else { return n + fail("pipeline bilevel", "\(levels) distinct levels, expected ≤8") }
            n += pass("pipeline bilevel", "\(levels) distinct luminance levels")

            // Invert must move the mean the other way.
            var inv = ScanSettings()
            inv.cropPreset = .maximum
            inv.colorBalance = .none
            inv.sharpen = .none
            let normal = try ImagePipeline(settings: inv, sourceDPI: 150, cropAlreadyApplied: true).process(raw)
            inv.invert = true
            let inverted = try ImagePipeline(settings: inv, sourceDPI: 150, cropAlreadyApplied: true).process(raw)
            let a = meanLuminance(normal), b = meanLuminance(inverted)
            guard a > b else { return n + fail("pipeline invert", "mean \(a) → \(b), expected a drop") }
            n += pass("pipeline invert", String(format: "mean %.3f → %.3f", a, b))
            return n
        } catch {
            return fail("pipeline", error.localizedDescription)
        }
    }

    private static func checkNaming(in dir: URL) async -> Int {
        var settings = ScanSettings()
        settings.outputFolder = dir
        settings.fileNameTemplate = "scan+.jpg"
        let writer = OutputWriter(settings: settings)

        let first = writer.resolveName(template: "scan+.jpg", ext: "jpg", in: dir)
        guard first.lastPathComponent == "scan0001.jpg" else {
            return fail("naming", "got \(first.lastPathComponent), expected scan0001.jpg")
        }
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = writer.resolveName(template: "scan+.jpg", ext: "jpg", in: dir)
        guard second.lastPathComponent == "scan0002.jpg" else {
            return fail("naming", "got \(second.lastPathComponent), expected scan0002.jpg")
        }
        try? FileManager.default.removeItem(at: first)

        let dated = writer.resolveName(template: "%date-page+.tif", ext: "tif", in: dir)
        guard dated.lastPathComponent.range(of: #"^\d{8}-page0001\.tif$"#,
                                            options: .regularExpression) != nil else {
            return fail("naming", "date token expanded to \(dated.lastPathComponent)")
        }
        return pass("naming", "scan0001 → scan0002, \(dated.lastPathComponent)")
    }

    private static func checkOutputFormats(in dir: URL) async -> Int {
        var settings = ScanSettings()
        settings.outputFolder = dir
        settings.fileNameTemplate = "out+.x"
        settings.scanResolution = 150
        settings.writeJPEG = true
        settings.writeTIFF = true
        settings.writePNG = true
        settings.writePDF = true
        settings.writeOCRText = true
        settings.pdfMultiPage = true
        settings.cropPreset = .maximum

        let request = ScanRequest(source: .flatbed, resolutionDPI: 150,
                                  areaMM: CGRect(x: 0, y: 0, width: 105, height: 148),
                                  bitDepth: .rgb24, isPreview: false)
        do {
            let raw = try SimulatedBackend.render(request: request)
            let pages = [ScanPage(image: raw, dpi: 150, index: 0),
                         ScanPage(image: raw, dpi: 150, index: 1)]
            let pipeline = ImagePipeline(settings: settings, sourceDPI: 150, cropAlreadyApplied: true)
            let processed = try pages.map { try pipeline.process($0.image) }

            let writer = OutputWriter(settings: settings)
            let result = try await writer.write(pages: pages, processed: processed)

            let exts = Set(result.files.map { $0.pathExtension })
            for required in ["jpg", "png", "tif", "pdf", "txt"] {
                guard exts.contains(required) else {
                    return fail("output", "no .\(required) written (got \(exts.sorted().joined(separator: ","))")
                }
            }
            for url in result.files {
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? Int) ?? 0
                guard size > 0 else { return fail("output", "\(url.lastPathComponent) is empty") }
            }
            // The PDF must carry both pages.
            guard let pdf = result.files.first(where: { $0.pathExtension == "pdf" }),
                  let doc = CGPDFDocument(pdf as CFURL) else {
                return fail("output", "PDF unreadable")
            }
            guard doc.numberOfPages == 2 else {
                return fail("output", "PDF has \(doc.numberOfPages) pages, expected 2")
            }
            // And its page box should match 105×148 mm in points.
            let expectedPts = 105.0 / 25.4 * 72
            let box = doc.page(at: 1)!.getBoxRect(.mediaBox)
            guard abs(box.width - expectedPts) < 3 else {
                return fail("output", String(format: "PDF page %.1f pt wide, expected ≈%.1f", box.width, expectedPts))
            }
            return pass("output", "\(result.files.count) files, PDF 2 pages @ \(Int(box.width))×\(Int(box.height)) pt")
        } catch {
            return fail("output", error.localizedDescription)
        }
    }

    private static func checkAutoCrop() -> Int {
        let w = 400, h = 500
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return fail("auto crop", "could not allocate test bitmap")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        let content = CGRect(x: 50, y: 80, width: 200, height: 300)
        ctx.fill(content)
        guard let image = ctx.makeImage(),
              let found = DocumentEdgeFinder.contentBounds(of: image) else {
            return fail("auto crop", "no content detected")
        }
        // contentBounds works in top-down rows, so y flips relative to the CG fill.
        let expectedY = Double(h) - content.maxY
        guard abs(found.origin.x - content.origin.x) < 6,
              abs(found.origin.y - expectedY) < 6,
              abs(found.width - content.width) < 6,
              abs(found.height - content.height) < 6 else {
            return fail("auto crop", "found \(rectDescription(found)), expected ≈(50, \(Int(expectedY)), 200, 300)")
        }
        return pass("auto crop", "found \(rectDescription(found))")
    }

    private static func checkESCLRequestXML() -> Int {
        let request = ScanRequest(source: .flatbed, resolutionDPI: 300,
                                  areaMM: CGRect(x: 0, y: 0, width: 215.9, height: 279.4),
                                  bitDepth: .rgb24, isPreview: false)
        let xml = ESCLRequestXML.settings(for: request)
        // 215.9 mm = 8.5 in = 2550 units of 1/300 inch.
        guard xml.contains("<pwg:Width>2550</pwg:Width>") else {
            return fail("eSCL XML", "width not 2550 units of 1/300 in")
        }
        guard xml.contains("<pwg:Height>3300</pwg:Height>") else {
            return fail("eSCL XML", "height not 3300 units of 1/300 in")
        }
        guard xml.contains("<scan:ColorMode>RGB24</scan:ColorMode>"),
              xml.contains("<pwg:InputSource>Platen</pwg:InputSource>"),
              xml.contains("<scan:XResolution>300</scan:XResolution>") else {
            return fail("eSCL XML", "colour mode / source / resolution missing")
        }
        // Must be well-formed, or the printer rejects the job outright.
        let parser = XMLParser(data: Data(xml.utf8))
        guard parser.parse() else {
            return fail("eSCL XML", "not well-formed: \(parser.parserError?.localizedDescription ?? "?")")
        }
        return pass("eSCL XML", "well-formed, 2550×3300 units, RGB24, Platen")
    }

    private static func checkCapabilitiesParse() -> Int {
        // Trimmed from a real HP DeskJet 2300 ScannerCapabilities response.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScannerCapabilities xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"
          xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">
          <pwg:MakeAndModel>HP DeskJet 2300 series</pwg:MakeAndModel>
          <scan:Platen>
            <scan:PlatenInputCaps>
              <scan:MinWidth>16</scan:MinWidth>
              <scan:MaxWidth>2550</scan:MaxWidth>
              <scan:MinHeight>16</scan:MinHeight>
              <scan:MaxHeight>3508</scan:MaxHeight>
              <scan:SettingProfiles><scan:SettingProfile>
                <scan:SupportedResolutions><scan:DiscreteResolutions>
                  <scan:DiscreteResolution><scan:XResolution>75</scan:XResolution><scan:YResolution>75</scan:YResolution></scan:DiscreteResolution>
                  <scan:DiscreteResolution><scan:XResolution>200</scan:XResolution><scan:YResolution>200</scan:YResolution></scan:DiscreteResolution>
                  <scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
                  <scan:DiscreteResolution><scan:XResolution>600</scan:XResolution><scan:YResolution>600</scan:YResolution></scan:DiscreteResolution>
                  <scan:DiscreteResolution><scan:XResolution>1200</scan:XResolution><scan:YResolution>1200</scan:YResolution></scan:DiscreteResolution>
                </scan:DiscreteResolutions></scan:SupportedResolutions>
              </scan:SettingProfile></scan:SettingProfiles>
            </scan:PlatenInputCaps>
          </scan:Platen>
        </scan:ScannerCapabilities>
        """
        let caps = ESCLCapabilities(xml: Data(xml.utf8))
        guard caps.makeAndModel == "HP DeskJet 2300 series" else {
            return fail("eSCL caps", "model parsed as \(caps.makeAndModel ?? "nil")")
        }
        guard caps.resolutions == [75, 200, 300, 600, 1200] else {
            return fail("eSCL caps", "resolutions \(caps.resolutions)")
        }
        guard let bed = caps.platenSizeMM, abs(bed.width - 215.9) < 0.5, abs(bed.height - 297.0) < 1.0 else {
            return fail("eSCL caps", "platen \(caps.platenSizeMM.map(sizeDescription) ?? "nil"), expected ≈215.9×297 mm")
        }
        // The 2300 is flatbed-only; a feeder must not be invented.
        guard caps.sources == [.flatbed] else {
            return fail("eSCL caps", "sources \(caps.sources.map(\.rawValue))")
        }
        return pass("eSCL caps", "\(caps.makeAndModel!), \(sizeDescription(bed)), \(caps.resolutions.count) resolutions, flatbed only")
    }

    private static func checkUIRender(in dir: URL) async -> Int {
        let controller = ScanController()
        // Give discovery a moment so the device picker is populated, then put a
        // preview on the canvas so the crop overlay has something to sit on.
        // Pin to the simulator: this check must not depend on attached hardware.
        try? await Task.sleep(nanoseconds: 800_000_000)
        controller.selectDevice(SimulatedBackend.deviceID)
        controller.preview()
        for _ in 0..<80 where controller.previewImage == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard controller.previewImage != nil else {
            return fail("UI render", "preview never arrived from the simulated scanner")
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        var written: [String] = []
        for tab in OptionTab.allCases {
            let view = ContentView(controller: controller, initialTab: tab)
            guard let url = capture(view, size: CGSize(width: 1180, height: 780),
                                    to: dir.appendingPathComponent("ui-\(tab.rawValue.lowercased()).png")) else {
                return fail("UI render", "could not capture the \(tab.rawValue) tab")
            }
            written.append(url.lastPathComponent)
        }
        return pass("UI render", written.joined(separator: ", "))
    }

    /// Renders a SwiftUI view through a real hosting view in an offscreen
    /// window. `ImageRenderer` cannot do this — anything AppKit-backed
    /// (HSplitView, segmented Picker, Slider) comes out as a "not supported"
    /// placeholder — but `cacheDisplay(in:to:)` walks the actual view tree.
    private static func capture<V: View>(_ view: V, size: CGSize, to url: URL) -> URL? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()
        // Let SwiftUI settle: one runloop pass is not always enough for
        // scroll views and pickers to size themselves.
        for _ in 0..<3 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    // MARK: Helpers

    private static func pass(_ name: String, _ detail: String) -> Int {
        print("  ok    \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(detail)")
        return 0
    }
    private static func fail(_ name: String, _ detail: String) -> Int {
        print("  FAIL  \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(detail)")
        return 1
    }
    private static func rectDescription(_ r: CGRect) -> String {
        String(format: "(%.0f, %.0f, %.0f, %.0f)", r.origin.x, r.origin.y, r.width, r.height)
    }
    private static func sizeDescription(_ s: CGSize) -> String {
        String(format: "%.1f×%.1f mm", s.width, s.height)
    }

    private static func meanLuminance(_ image: CGImage) -> Double {
        guard let stats = ImagePipeline.averageColor(CIImage(cgImage: image)) else { return 0 }
        return 0.2126 * stats.r + 0.7152 * stats.g + 0.0722 * stats.b
    }

    private static func distinctLuminanceCount(_ image: CGImage) -> Int {
        let w = min(image.width, 200), h = min(image.height, 200)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 999 }
        // Nearest-neighbour only: smoothing would manufacture grey levels that
        // are not in the image and make a correct bilevel result look analogue.
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let data = ctx.data else { return 999 }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        var seen = Set<UInt8>()
        for i in 0..<(w * h) { seen.insert(px[i]) }
        return seen.count
    }
}
