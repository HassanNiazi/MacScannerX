import Foundation
import CoreGraphics
import ImageIO

/// Direct AirScan / eSCL driver.
///
/// This is the path that reaches an HP DeskJet 2300 over Wi-Fi with no HP
/// software installed at all: the printer advertises `_uscan._tcp`, and we
/// drive it with the PWG/eSCL REST protocol (ScannerCapabilities → ScanJobs →
/// NextDocument). Kept as a peer of `ImageCaptureBackend` because ICA
/// occasionally refuses to enumerate network-only scanners.
final class ESCLBackend: NSObject, ScannerBackend {

    private let browser = NetServiceBrowser()
    private let secureBrowser = NetServiceBrowser()
    private var resolving: Set<NetService> = []
    private var endpoints: [String: ESCLEndpoint] = [:]
    private var onChange: (([ScannerDeviceInfo]) -> Void)?
    private var currentJob: URL?
    private var isCancelled = false

    private(set) var devices: [ScannerDeviceInfo] = []

    struct ESCLEndpoint {
        let baseURL: URL      // http://192.168.1.7:8080/eSCL
        let name: String
        let model: String
        var capabilities: ESCLCapabilities?
    }

    override init() {
        super.init()
        browser.delegate = self
        secureBrowser.delegate = self
    }

    // MARK: Discovery

    func startDiscovery(onChange: @escaping ([ScannerDeviceInfo]) -> Void) {
        self.onChange = onChange
        browser.searchForServices(ofType: "_uscan._tcp.", inDomain: "local.")
        secureBrowser.searchForServices(ofType: "_uscans._tcp.", inDomain: "local.")
    }

    func stopDiscovery() {
        browser.stop()
        secureBrowser.stop()
        onChange = nil
    }

    private func publish() {
        let list = endpoints.map { key, ep -> ScannerDeviceInfo in
            ScannerDeviceInfo(
                id: key,
                name: ep.name,
                model: ep.model,
                transport: .network,
                bedSizeMM: ep.capabilities?.platenSizeMM,
                supportedSources: ep.capabilities?.sources ?? [.flatbed],
                supportedResolutions: ep.capabilities?.resolutions ?? [75, 100, 200, 300, 600, 1200],
                isReady: true
            )
        }.sorted { $0.name < $1.name }
        devices = list
        DispatchQueue.main.async { [onChange] in onChange?(list) }
    }

    // MARK: Probe

    func probe(deviceID: String) async throws -> ScannerDeviceInfo {
        guard var ep = endpoints[deviceID] else { throw ScanError.deviceUnavailable(deviceID) }
        let caps = try await fetchCapabilities(base: ep.baseURL)
        ep.capabilities = caps
        endpoints[deviceID] = ep
        publish()
        return ScannerDeviceInfo(
            id: deviceID, name: ep.name, model: ep.model, transport: .network,
            bedSizeMM: caps.platenSizeMM, supportedSources: caps.sources,
            supportedResolutions: caps.resolutions, isReady: true
        )
    }

    private func fetchCapabilities(base: URL) async throws -> ESCLCapabilities {
        let url = base.appendingPathComponent("ScannerCapabilities")
        let (data, response) = try await URLSession.escl.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ScanError.badResponse("ScannerCapabilities returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return ESCLCapabilities(xml: data)
    }

    // MARK: Scan

    func scan(deviceID: String, request: ScanRequest, progress: @escaping ScanProgress) async throws -> [ScanPage] {
        guard let ep = endpoints[deviceID] else { throw ScanError.deviceUnavailable(deviceID) }
        isCancelled = false

        progress(0.05, "Posting scan job")
        let jobURL = try await createJob(base: ep.baseURL, request: request)
        currentJob = jobURL
        defer { currentJob = nil }

        var pages: [ScanPage] = []
        let maxPages = (request.source == .flatbed) ? 1 : 50

        while pages.count < maxPages {
            if isCancelled { throw ScanError.cancelled }
            progress(0.2 + 0.7 * Double(pages.count) / Double(max(1, maxPages)),
                     "Retrieving page \(pages.count + 1)")
            guard let image = try await nextDocument(job: jobURL) else { break }
            pages.append(ScanPage(image: image, dpi: request.resolutionDPI, index: pages.count))
            if request.source == .flatbed { break }
        }

        guard !pages.isEmpty else { throw ScanError.transferFailed("scanner returned no pages") }
        progress(1.0, "Done")
        return pages
    }

    private func createJob(base: URL, request: ScanRequest) async throws -> URL {
        var req = URLRequest(url: base.appendingPathComponent("ScanJobs"))
        req.httpMethod = "POST"
        req.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        req.httpBody = ESCLRequestXML.settings(for: request).data(using: .utf8)
        req.timeoutInterval = 30

        let (_, response) = try await URLSession.escl.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ScanError.badResponse("no HTTP response to ScanJobs")
        }
        guard http.statusCode == 201, let location = http.value(forHTTPHeaderField: "Location") else {
            throw ScanError.badResponse("ScanJobs returned \(http.statusCode)")
        }
        // Some firmwares return a bare path, others a full URL.
        if let absolute = URL(string: location), absolute.scheme != nil { return absolute }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = location
        guard let url = comps.url else { throw ScanError.badResponse("bad job Location: \(location)") }
        return url
    }

    /// Returns nil when the device signals end-of-job with 404 / 410.
    private func nextDocument(job: URL) async throws -> CGImage? {
        var req = URLRequest(url: job.appendingPathComponent("NextDocument"))
        req.httpMethod = "GET"
        req.timeoutInterval = 180

        let (data, response) = try await URLSession.escl.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ScanError.badResponse("no HTTP response to NextDocument")
        }
        if http.statusCode == 404 || http.statusCode == 410 { return nil }
        guard http.statusCode == 200 else {
            throw ScanError.transferFailed("NextDocument returned \(http.statusCode)")
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ScanError.transferFailed("could not decode \(data.count) bytes from scanner")
        }
        return image
    }

    func cancel() {
        isCancelled = true
        guard let job = currentJob else { return }
        var req = URLRequest(url: job)
        req.httpMethod = "DELETE"
        Task { _ = try? await URLSession.escl.data(for: req) }
    }
}

// MARK: - Bonjour delegates

extension ESCLBackend: NetServiceBrowserDelegate, NetServiceDelegate {

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.insert(service)
        service.resolve(withTimeout: 6)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        endpoints = endpoints.filter { !$0.value.name.hasPrefix(service.name) }
        if !moreComing { publish() }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolving.remove(sender) }
        guard let host = Self.ipv4(from: sender) else { return }

        var resourcePath = "eSCL"
        var model = sender.name
        if let txtData = sender.txtRecordData() {
            let txt = NetService.dictionary(fromTXTRecord: txtData)
            if let rs = txt["rs"], let s = String(data: rs, encoding: .utf8), !s.isEmpty { resourcePath = s }
            if let ty = txt["ty"], let s = String(data: ty, encoding: .utf8), !s.isEmpty { model = s }
        }

        let scheme = sender.type.hasPrefix("_uscans") ? "https" : "http"
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = sender.port
        comps.path = "/" + resourcePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = comps.url else { return }

        let key = "escl:" + base.absoluteString
        endpoints[key] = ESCLEndpoint(baseURL: base, name: sender.name, model: model, capabilities: nil)
        publish()

        // Fill in real capabilities in the background so the UI can show true limits.
        Task { [weak self] in
            guard let self, var ep = self.endpoints[key] else { return }
            if let caps = try? await self.fetchCapabilities(base: base) {
                ep.capabilities = caps
                self.endpoints[key] = ep
                self.publish()
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(sender)
    }

    private static func ipv4(from service: NetService) -> String? {
        for data in service.addresses ?? [] {
            let host: String? = data.withUnsafeBytes { raw -> String? in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
                guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buf)
            }
            if let host { return host }
        }
        return nil
    }
}

// MARK: - eSCL XML

enum ESCLRequestXML {
    /// eSCL measures regions in 1/300 inch, regardless of scan resolution.
    private static func units(_ mm: Double) -> Int { Int((mm / 25.4 * 300).rounded()) }

    static func settings(for request: ScanRequest) -> String {
        let colorMode: String
        switch request.bitDepth {
        case .bw1:                  colorMode = "BlackAndWhite1"
        case .gray8:                colorMode = "Grayscale8"
        case .gray16:               colorMode = "Grayscale16"
        case .rgb24:                colorMode = "RGB24"
        case .rgb48:                colorMode = "RGB48"
        }
        let input: String
        switch request.source {
        case .flatbed:      input = "Platen"
        case .feeder:       input = "Feeder"
        case .feederDuplex: input = "Feeder"
        }
        let duplex = request.source == .feederDuplex ? "<scan:Duplex>true</scan:Duplex>" : ""
        let intent = request.isPreview ? "Preview" : "Document"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm" \
        xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">
          <pwg:Version>2.63</pwg:Version>
          <scan:Intent>\(intent)</scan:Intent>
          <pwg:ScanRegions pwg:MustHonor="true">
            <pwg:ScanRegion>
              <pwg:XOffset>\(units(request.areaMM.origin.x))</pwg:XOffset>
              <pwg:YOffset>\(units(request.areaMM.origin.y))</pwg:YOffset>
              <pwg:Width>\(units(request.areaMM.width))</pwg:Width>
              <pwg:Height>\(units(request.areaMM.height))</pwg:Height>
              <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
            </pwg:ScanRegion>
          </pwg:ScanRegions>
          <pwg:InputSource>\(input)</pwg:InputSource>
          \(duplex)
          <scan:ColorMode>\(colorMode)</scan:ColorMode>
          <scan:XResolution>\(request.resolutionDPI)</scan:XResolution>
          <scan:YResolution>\(request.resolutionDPI)</scan:YResolution>
          <scan:Brightness>\(Int(1000 + request.deviceBrightness * 10))</scan:Brightness>
          <scan:Contrast>\(Int(1000 + request.deviceContrast * 10))</scan:Contrast>
          <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
        </scan:ScanSettings>
        """
    }
}

/// Minimal, tolerant parse of ScannerCapabilities — firmwares differ wildly in
/// namespace prefixes, so we key on local element names only.
struct ESCLCapabilities {
    var platenSizeMM: CGSize?
    var sources: [ScanSource] = [.flatbed]
    var resolutions: [Int] = []
    var makeAndModel: String?

    init(xml data: Data) {
        let parser = Parser()
        let x = XMLParser(data: data)
        x.delegate = parser
        x.shouldProcessNamespaces = false
        x.parse()

        makeAndModel = parser.makeAndModel
        if parser.hasFeeder { sources.append(.feeder) }
        if parser.hasDuplex { sources.append(.feederDuplex) }
        resolutions = Array(Set(parser.resolutions)).sorted()
        if let w = parser.platenWidth, let h = parser.platenHeight {
            // Capability extents are in 1/300 inch.
            platenSizeMM = CGSize(width: Double(w) / 300 * 25.4, height: Double(h) / 300 * 25.4)
        }
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var makeAndModel: String?
        var hasFeeder = false
        var hasDuplex = false
        var resolutions: [Int] = []
        var platenWidth: Int?
        var platenHeight: Int?

        private var element = ""
        private var buffer = ""
        private var inPlaten = false

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            element = name.components(separatedBy: ":").last ?? name
            buffer = ""
            if element == "Platen" || element == "PlatenInputCaps" { inPlaten = true }
            if element == "Adf" || element == "AdfSimplexInputCaps" { hasFeeder = true }
            if element == "AdfDuplexInputCaps" { hasDuplex = true; hasFeeder = true }
        }

        func parser(_ p: XMLParser, foundCharacters string: String) { buffer += string }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let local = name.components(separatedBy: ":").last ?? name
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local {
            case "MakeAndModel":  makeAndModel = value
            case "XResolution":   if let n = Int(value) { resolutions.append(n) }
            case "MaxWidth":      if inPlaten, let n = Int(value) { platenWidth = n }
            case "MaxHeight":     if inPlaten, let n = Int(value) { platenHeight = n }
            case "Platen", "PlatenInputCaps": inPlaten = false
            default: break
            }
            buffer = ""
        }
    }
}

extension URLSession {
    /// eSCL scans can take minutes; the shared session's defaults are too tight.
    /// Printers ship self-signed certs, so `_uscans` needs a permissive delegate.
    static let escl: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: TrustAnyPrinter(), delegateQueue: nil)
    }()
}

private final class TrustAnyPrinter: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
