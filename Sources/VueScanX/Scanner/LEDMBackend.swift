import Foundation
import CoreGraphics
import ImageIO
import CHPUSB

/// Drives an HP all-in-one over USB using LEDM — HP's XML-over-HTTP scan API,
/// served from a vendor-specific USB interface.
///
/// This is the path that reaches an HP DeskJet 2300 plugged in over USB, where
/// macOS offers nothing: the printer has no IPP-USB interface, so there is no
/// AirScan, and no ImageCaptureCore driver is installed for it. The flow is
///
///   GET  /Scan/ScanCaps          → capabilities
///   POST /Scan/Jobs              → 201 + Location
///   GET  {Location}              → poll until a BinaryURL appears
///   GET  {BinaryURL}             → JPEG bytes
///
/// All USB work happens on a dedicated serial queue; the calls block.
final class LEDMBackend: ScannerBackend {

    private let queue = DispatchQueue(label: "com.local.vuescanx.ledm", qos: .userInitiated)
    private var onChange: (([ScannerDeviceInfo]) -> Void)?
    private var timer: DispatchSourceTimer?
    private var capabilityCache: [String: LEDMCapabilities] = [:]
    private let lock = NSLock()
    private var cancelled = false
    /// Suppresses the discovery capability probe while a page is in flight.
    private var isScanning = false

    private(set) var devices: [ScannerDeviceInfo] = []

    /// `ledm:<locationID>` — stable for as long as the printer stays in the port.
    static func deviceID(locationID: UInt32) -> String { "ledm:\(locationID)" }
    static func locationID(from deviceID: String) -> UInt32? {
        guard deviceID.hasPrefix("ledm:") else { return nil }
        return UInt32(deviceID.dropFirst("ledm:".count))
    }

    // MARK: Discovery

    func startDiscovery(onChange: @escaping ([ScannerDeviceInfo]) -> Void) {
        self.onChange = onChange
        refresh()
        // USB attach/detach has no cheap notification here, so poll gently.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func stopDiscovery() {
        timer?.cancel()
        timer = nil
        onChange = nil
    }

    private func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            var buffer = [hpusb_device_info](repeating: hpusb_device_info(), count: Int(HPUSB_MAX_DEVICES))
            let count = buffer.withUnsafeMutableBufferPointer { buf in
                hpusb_enumerate(buf.baseAddress, Int32(buf.count))
            }
            guard count > 0 else {
                self.publish([])
                return
            }

            // Publish straight from the registry first. Talking to the device
            // takes seconds when it is busy, and discovery must never block on
            // it or the scanner appears to vanish mid-scan.
            var found: [ScannerDeviceInfo] = []
            var needCapabilities: [(String, UInt32)] = []

            for i in 0..<Int(count) {
                let raw = buffer[i]
                let name = withUnsafeBytes(of: raw.product) { bytes -> String in
                    String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                let serial = withUnsafeBytes(of: raw.serial) { bytes -> String in
                    String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                let id = Self.deviceID(locationID: raw.location_id)

                self.lock.lock()
                let caps = self.capabilityCache[id]
                self.lock.unlock()
                if caps == nil { needCapabilities.append((id, raw.location_id)) }

                found.append(ScannerDeviceInfo(
                    id: id,
                    name: caps?.modelName ?? (name.isEmpty ? "HP scanner" : name),
                    model: serial.isEmpty ? name : "\(name) · \(serial)",
                    transport: .usb,
                    bedSizeMM: caps?.platenSizeMM,
                    supportedSources: caps?.sources ?? [.flatbed],
                    supportedResolutions: caps?.resolutions ?? [75, 100, 200, 300, 600, 1200],
                    isReady: true
                ))
            }
            self.publish(found)

            // Then fill in real capabilities, cheaply, and republish if they land.
            guard !self.isScanning else { return }
            var learned = false
            for (id, location) in needCapabilities {
                guard let caps = try? self.fetchCapabilities(locationID: location,
                                                             quick: true) else { continue }
                self.lock.lock(); self.capabilityCache[id] = caps; self.lock.unlock()
                learned = true
            }
            if learned { self.refreshFromCache(found) }
        }
    }

    /// Re-emits an already-published list with whatever capabilities are now known.
    private func refreshFromCache(_ list: [ScannerDeviceInfo]) {
        let updated = list.map { device -> ScannerDeviceInfo in
            lock.lock()
            let caps = capabilityCache[device.id]
            lock.unlock()
            guard let caps else { return device }
            var copy = device
            copy = ScannerDeviceInfo(
                id: device.id,
                name: caps.modelName ?? device.name,
                model: device.model,
                transport: .usb,
                bedSizeMM: caps.platenSizeMM,
                supportedSources: caps.sources,
                supportedResolutions: caps.resolutions,
                isReady: true
            )
            return copy
        }
        publish(updated)
    }

    private func publish(_ list: [ScannerDeviceInfo]) {
        let sorted = list.sorted { $0.name < $1.name }
        guard sorted != devices else { return }
        devices = sorted
        DispatchQueue.main.async { [onChange] in onChange?(sorted) }
    }

    /// `quick` is for the discovery path: a small drain budget, a short timeout
    /// and no retry, so a busy scanner costs a second rather than a minute.
    private func fetchCapabilities(locationID: UInt32, quick: Bool = false) throws -> LEDMCapabilities {
        let client = try USBHTTPClient(locationID: locationID,
                                       drainBudget: quick ? 0.8 : 6)
        defer { client.close() }
        let response = try client.request(method: "GET", path: "/Scan/ScanCaps",
                                          timeout: quick ? 4 : 15,
                                          allowRetry: !quick)
        guard response.status == 200 else {
            throw ScanError.badResponse("/Scan/ScanCaps returned \(response.status)")
        }
        return LEDMCapabilities(xml: response.body)
    }

    // MARK: Probe

    func probe(deviceID: String) async throws -> ScannerDeviceInfo {
        guard let location = Self.locationID(from: deviceID) else {
            throw ScanError.deviceUnavailable(deviceID)
        }
        // Cache mutation happens on the USB queue, so the lock is never taken
        // from an async context.
        let caps = try await run { () -> LEDMCapabilities in
            let fresh = try self.fetchCapabilities(locationID: location)
            self.lock.lock()
            self.capabilityCache[deviceID] = fresh
            self.lock.unlock()
            return fresh
        }

        let existing = devices.first { $0.id == deviceID }
        return ScannerDeviceInfo(
            id: deviceID,
            name: caps.modelName ?? existing?.name ?? "HP scanner",
            model: existing?.model ?? "",
            transport: .usb,
            bedSizeMM: caps.platenSizeMM,
            supportedSources: caps.sources,
            supportedResolutions: caps.resolutions,
            isReady: true
        )
    }

    // MARK: Scan

    func scan(deviceID: String, request: ScanRequest,
              progress: @escaping ScanProgress) async throws -> [ScanPage] {
        guard let location = Self.locationID(from: deviceID) else {
            throw ScanError.deviceUnavailable(deviceID)
        }
        cancelled = false
        return try await run {
            self.isScanning = true
            defer { self.isScanning = false }
            return try self.performScan(locationID: location, request: request, progress: progress)
        }
    }

    private func performScan(locationID: UInt32, request: ScanRequest,
                             progress: @escaping ScanProgress) throws -> [ScanPage] {
        do {
            return try attemptScan(locationID: locationID, request: request, progress: progress)
        } catch let error as USBHTTPClient.ClientError {
            // The printer's HTTP server wedges if a job is ever abandoned, and
            // then refuses everything. A USB reset is the only way back without
            // power-cycling it by hand.
            switch error {
            case .writeFailed, .noResponse, .readFailed:
                progress(0.02, "Resetting scanner")
                if let recovery = try? USBHTTPClient(locationID: locationID) {
                    recovery.resync(budget: 25)
                    _ = recovery.resetDevice()
                    recovery.close()
                }
                Thread.sleep(forTimeInterval: 4)
                return try attemptScan(locationID: locationID, request: request, progress: progress)
            default:
                throw error
            }
        }
    }

    private func attemptScan(locationID: UInt32, request: ScanRequest,
                             progress: @escaping ScanProgress) throws -> [ScanPage] {
        let client = try USBHTTPClient(locationID: locationID)
        defer { client.close() }

        progress(0.05, "Starting scan job")
        let job = LEDMScanJob(request: request)
        let created = try client.post("/Scan/Jobs", body: Data(job.xml.utf8), timeout: 30)
        guard created.status == 201 else {
            throw ScanError.badResponse("POST /Scan/Jobs returned \(created.status)")
        }
        guard let location = created.header("Location") else {
            throw ScanError.badResponse("scan job created without a Location header")
        }
        let jobPath = USBHTTPClient.pathComponent(of: location)

        // Abandoning a job leaves the device pushing page data for minutes and
        // refusing new work, which poisons every later scan. Always release it.
        var jobReleased = false
        func releaseJob() {
            guard !jobReleased else { return }
            jobReleased = true
            _ = try? client.delete(jobPath)
            client.resync(budget: 25)
        }
        defer { releaseJob() }

        progress(0.12, "Warming up")
        var binaryURL: String?
        // The lamp and carriage take a few seconds before page data exists.
        for attempt in 0..<90 {
            if cancelled { throw ScanError.cancelled }
            // A poll that lands mid-warm-up can go unanswered; that is not fatal.
            guard let status = try? client.request(method: "GET", path: jobPath,
                                                   timeout: 15, allowRetry: false) else {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let text = status.text
            if let url = LEDMScanJob.binaryURL(in: text) {
                binaryURL = url
                break
            }
            if let state = LEDMScanJob.jobState(in: text) {
                if state.caseInsensitiveCompare("Aborted") == .orderedSame
                    || state.caseInsensitiveCompare("Canceled") == .orderedSame {
                    throw ScanError.transferFailed("scanner reported job \(state)")
                }
                progress(min(0.35, 0.12 + Double(attempt) * 0.01), "Scanner \(state.lowercased())")
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        guard let binaryURL else {
            throw ScanError.transferFailed("scanner never produced page data")
        }

        progress(0.4, "Reading page")
        // A full-bed 600 dpi page is ~35 megapixels and streams for a while; the
        // read deadline restarts on every packet, so this bounds silence, not
        // total transfer time.
        let image = try client.request(method: "GET", path: binaryURL,
                                       timeout: 45, allowRetry: false)
        guard image.status == 200 else {
            throw ScanError.transferFailed("page fetch returned \(image.status)")
        }
        guard !image.body.isEmpty,
              let source = CGImageSourceCreateWithData(image.body as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScanError.transferFailed("could not decode \(image.body.count) bytes from the scanner")
        }

        progress(1.0, "Done")
        releaseJob()
        return [ScanPage(image: cgImage, dpi: request.resolutionDPI, index: 0)]
    }

    func cancel() { cancelled = true }

    // MARK: Queue bridge

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

// MARK: - Scan job XML

struct LEDMScanJob {
    let request: ScanRequest

    /// LEDM geometry is in 1/300 inch, same as eSCL.
    private static func units(_ mm: Double) -> Int { Int((mm / 25.4 * 300).rounded()) }

    var xml: String {
        // K1 (1-bit) is Raw-only on these devices, so always acquire 8-bit and
        // let the image pipeline threshold it — better results anyway.
        let colorSpace = request.bitDepth.channels == 1 ? "Gray" : "Color"
        let x = Self.units(request.areaMM.origin.x)
        let y = Self.units(request.areaMM.origin.y)
        let w = max(8, Self.units(request.areaMM.width))
        let h = max(8, Self.units(request.areaMM.height))
        // Preview passes trade quality for speed.
        let quality = request.isPreview ? 25 : 15

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanJob xmlns:scan="http://www.hp.com/schemas/imaging/con/cnx/scan/2008/08/19" \
        xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
        <scan:XResolution>\(request.resolutionDPI)</scan:XResolution>
        <scan:YResolution>\(request.resolutionDPI)</scan:YResolution>
        <scan:XStart>\(x)</scan:XStart>
        <scan:YStart>\(y)</scan:YStart>
        <scan:Width>\(w)</scan:Width>
        <scan:Height>\(h)</scan:Height>
        <scan:Format>Jpeg</scan:Format>
        <scan:CompressionQFactor>\(quality)</scan:CompressionQFactor>
        <scan:ColorSpace>\(colorSpace)</scan:ColorSpace>
        <scan:BitDepth>8</scan:BitDepth>
        <scan:InputSource>Platen</scan:InputSource>
        <scan:GrayRendering>NTSC</scan:GrayRendering>
        <scan:ToneMap>
        <scan:Gamma>1000</scan:Gamma>
        <scan:Brightness>\(1000 + Int(request.deviceBrightness * 10))</scan:Brightness>
        <scan:Contrast>\(1000 + Int(request.deviceContrast * 10))</scan:Contrast>
        <scan:Highlite>179</scan:Highlite>
        <scan:Shadow>25</scan:Shadow>
        <scan:Threshold>0</scan:Threshold>
        </scan:ToneMap>
        <scan:ContentType>\(request.isPreview ? "Photo" : "Document")</scan:ContentType>
        </scan:ScanJob>
        """
    }

    static func binaryURL(in xml: String) -> String? {
        element("BinaryURL", in: xml)
    }
    static func jobState(in xml: String) -> String? {
        element("JobState", in: xml) ?? element("PageState", in: xml)
    }

    /// Namespace prefixes vary between firmwares, so match on the local name.
    private static func element(_ name: String, in xml: String) -> String? {
        guard let openRange = xml.range(of: "<[A-Za-z0-9]*:?\(name)>",
                                        options: .regularExpression) else { return nil }
        let rest = xml[openRange.upperBound...]
        guard let close = rest.range(of: "</") else { return nil }
        let value = rest[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Capabilities

struct LEDMCapabilities {
    var modelName: String?
    var platenSizeMM: CGSize?
    var resolutions: [Int] = []
    var sources: [ScanSource] = [.flatbed]
    var supportsColor = true
    var supportsGray = true

    init(xml data: Data) {
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        xml.parse()

        modelName = parser.modelName
        resolutions = Array(Set(parser.resolutions)).sorted()
        supportsColor = parser.colorTypes.contains("Color8")
        supportsGray = parser.colorTypes.contains("Gray8")
        if parser.hasAdf { sources.append(.feeder) }
        if let w = parser.maxWidth, let h = parser.maxHeight {
            // Capability extents are in 1/300 inch.
            platenSizeMM = CGSize(width: Double(w) / 300 * 25.4,
                                  height: Double(h) / 300 * 25.4)
        }
        if resolutions.isEmpty { resolutions = [75, 100, 200, 300, 600, 1200] }
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var modelName: String?
        var resolutions: [Int] = []
        var colorTypes: Set<String> = []
        var maxWidth: Int?
        var maxHeight: Int?
        var hasAdf = false

        private var buffer = ""
        private var inPlaten = false

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            let local = name.components(separatedBy: ":").last ?? name
            buffer = ""
            if local == "Platen" { inPlaten = true }
            if local == "Adf" || local == "AdfSimplex" { hasAdf = true }
        }

        func parser(_ p: XMLParser, foundCharacters string: String) { buffer += string }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let local = name.components(separatedBy: ":").last ?? name
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local {
            case "ModelName":   modelName = value
            case "ColorType":   colorTypes.insert(value)
            case "XResolution": if inPlaten, let n = Int(value) { resolutions.append(n) }
            case "MaxWidth":    if inPlaten, let n = Int(value) { maxWidth = n }
            case "MaxHeight":   if inPlaten, let n = Int(value) { maxHeight = n }
            case "Platen":      inPlaten = false
            default: break
            }
            buffer = ""
        }
    }
}
