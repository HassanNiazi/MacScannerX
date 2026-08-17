import Foundation
import ImageCaptureCore
import CoreGraphics
import ImageIO
import AppKit

/// Talks to any scanner macOS already knows about — USB, Bonjour/eSCL, or a
/// scanner shared from another Mac. This is the path an HP DeskJet 2300 takes
/// when it is plugged in over USB or paired over Wi-Fi with HP Easy Scan /
/// AirScan drivers present.
final class ImageCaptureBackend: NSObject, ScannerBackend {

    private let browser = ICDeviceBrowser()
    private var onChange: (([ScannerDeviceInfo]) -> Void)?
    private var known: [String: ICScannerDevice] = [:]
    private(set) var devices: [ScannerDeviceInfo] = []

    /// One in-flight operation at a time; ICA sessions are not re-entrant.
    private var pendingOpen: CheckedContinuation<Void, Error>?
    private var pendingUnit: CheckedContinuation<Void, Error>?
    private var pendingScan: CheckedContinuation<[ScanPage], Error>?
    private var collectedPages: [ScanPage] = []
    private var progressHandler: ScanProgress?
    private var activeRequest: ScanRequest?
    private var isCancelled = false

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.scanner.rawValue |
            ICDeviceLocationTypeMask.local.rawValue |
            ICDeviceLocationTypeMask.shared.rawValue |
            ICDeviceLocationTypeMask.bonjour.rawValue |
            ICDeviceLocationTypeMask.remote.rawValue
        )!
    }

    // MARK: Discovery

    func startDiscovery(onChange: @escaping ([ScannerDeviceInfo]) -> Void) {
        self.onChange = onChange
        browser.start()
    }

    func stopDiscovery() {
        browser.stop()
        onChange = nil
    }

    private func publish() {
        let list = known.values.map { Self.info(for: $0) }
            .sorted { $0.name < $1.name }
        devices = list
        DispatchQueue.main.async { [onChange] in onChange?(list) }
    }

    private static func info(for device: ICScannerDevice) -> ScannerDeviceInfo {
        let transport: DeviceTransport
        switch device.transportType {
        case ICDeviceTransport.transportTypeUSB.rawValue:   transport = .usb
        case ICDeviceTransport.transportTypeTCPIP.rawValue: transport = .network
        default:                            transport = .shared
        }

        var sources: [ScanSource] = []
        var resolutions: [Int] = []
        var bed: CGSize?

        for unit in device.availableFunctionalUnitTypes {
            switch ICScannerFunctionalUnitType(rawValue: unit.uintValue) {
            case .some(.flatbed):           sources.append(.flatbed)
            case .some(.documentFeeder):    sources.append(.feeder)
            default:                        break
            }
        }
        if sources.isEmpty { sources = [.flatbed] }

        let unit = device.selectedFunctionalUnit
        resolutions = unit.supportedResolutions.map { $0 }
        // physicalSize is expressed in `unit.measurementUnit`.
        let physical = Self.toMM(unit.physicalSize, unit: unit.measurementUnit)
        if physical.width > 0, physical.height > 0 { bed = physical }
        if resolutions.isEmpty { resolutions = [75, 100, 150, 200, 300, 600, 1200] }

        return ScannerDeviceInfo(
            id: device.uuidString ?? device.name ?? UUID().uuidString,
            name: device.name ?? "Scanner",
            model: device.usbProductID != 0 ? "USB \(device.usbVendorID):\(device.usbProductID)" : (device.name ?? ""),
            transport: transport,
            bedSizeMM: bed,
            supportedSources: sources,
            supportedResolutions: resolutions.sorted(),
            isReady: device.hasOpenSession
        )
    }

    private static func toMM(_ size: NSSize, unit: ICScannerMeasurementUnit) -> CGSize {
        switch unit {
        case .inches:       return CGSize(width: size.width * 25.4, height: size.height * 25.4)
        case .centimeters:  return CGSize(width: size.width * 10, height: size.height * 10)
        case .picas:        return CGSize(width: size.width * 4.2333, height: size.height * 4.2333)
        case .points:       return CGSize(width: size.width * 0.352778, height: size.height * 0.352778)
        case .twips:        return CGSize(width: size.width * 0.0176389, height: size.height * 0.0176389)
        case .pixels:       return size   // caller must scale by dpi; treated as mm-ish fallback
        @unknown default:   return size
        }
    }

    // MARK: Probe

    func probe(deviceID: String) async throws -> ScannerDeviceInfo {
        guard let device = known[deviceID] else { throw ScanError.deviceUnavailable(deviceID) }
        try await openSession(device)
        try await selectFunctionalUnit(device, source: .flatbed)
        return Self.info(for: device)
    }

    // MARK: Scan

    func scan(deviceID: String, request: ScanRequest, progress: @escaping ScanProgress) async throws -> [ScanPage] {
        guard let device = known[deviceID] else { throw ScanError.deviceUnavailable(deviceID) }
        isCancelled = false
        progressHandler = progress
        activeRequest = request
        collectedPages = []

        progress(0.02, "Opening session")
        try await openSession(device)

        progress(0.08, "Selecting \(request.source.rawValue)")
        try await selectFunctionalUnit(device, source: request.source)

        configure(unit: device.selectedFunctionalUnit, device: device, request: request)

        progress(0.15, request.isPreview ? "Previewing" : "Scanning")

        let pages: [ScanPage] = try await withCheckedThrowingContinuation { cont in
            pendingScan = cont
            device.requestScan()
        }

        if request.source == .flatbed {
            // Leave feeder sessions open so a batch can keep pulling pages.
            try? await device.requestCloseSession()
        }
        progressHandler = nil
        return pages
    }

    private func configure(unit: ICScannerFunctionalUnit, device: ICScannerDevice, request: ScanRequest) {
        // TWAIN — and therefore ICA — has no millimetre unit, so work in
        // centimetres and scale the mm request down by ten.
        unit.measurementUnit = .centimeters

        // Clamp the requested area to what the bed actually offers.
        let physical = unit.physicalSize   // already in centimetres after the line above
        let maxW = physical.width > 0 ? physical.width : 21.59
        let maxH = physical.height > 0 ? physical.height : 29.7
        var area = CGRect(x: request.areaMM.origin.x / 10, y: request.areaMM.origin.y / 10,
                          width: request.areaMM.width / 10, height: request.areaMM.height / 10)
        area.origin.x = max(0, min(area.origin.x, maxW - 0.1))
        area.origin.y = max(0, min(area.origin.y, maxH - 0.1))
        area.size.width = max(0.1, min(area.size.width, maxW - area.origin.x))
        area.size.height = max(0.1, min(area.size.height, maxH - area.origin.y))
        unit.scanArea = area

        // Resolution: snap to the nearest resolution the hardware advertises.
        let supported = (unit.supportedResolutions as IndexSet).map { $0 }
        let target = request.resolutionDPI
        unit.resolution = supported.isEmpty
            ? target
            : (supported.min(by: { abs($0 - target) < abs($1 - target) }) ?? target)

        switch request.bitDepth {
        case .bw1:
            unit.pixelDataType = .BW
            unit.bitDepth = .depth1Bit
        case .gray8:
            unit.pixelDataType = .gray
            unit.bitDepth = .depth8Bits
        case .gray16:
            unit.pixelDataType = .gray
            unit.bitDepth = .depth16Bits
        case .rgb24:
            unit.pixelDataType = .RGB
            unit.bitDepth = .depth8Bits
        case .rgb48:
            unit.pixelDataType = .RGB
            unit.bitDepth = .depth16Bits
        }

        if let flatbed = unit as? ICScannerFunctionalUnitFlatbed {
            _ = flatbed  // no flatbed-specific knobs needed beyond the above
        }
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.duplexScanningEnabled = (request.source == .feederDuplex)
            feeder.documentType = .typeA4
        }

        device.transferMode = .fileBased
        device.downloadsDirectory = Self.spoolDirectory
        device.documentName = request.isPreview ? "msx-preview" : "msx-scan"
        device.documentUTI = kUTTypeTIFF as String
    }

    static let spoolDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScannerX-spool", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func cancel() {
        isCancelled = true
        for device in known.values where device.hasOpenSession {
            device.cancelScan()
        }
        finishScan(.failure(ScanError.cancelled))
    }

    // MARK: Session plumbing

    private func openSession(_ device: ICScannerDevice) async throws {
        if device.hasOpenSession { return }
        device.delegate = self
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingOpen = cont
            device.requestOpenSession()
        }
    }

    private func selectFunctionalUnit(_ device: ICScannerDevice, source: ScanSource) async throws {
        let wanted: ICScannerFunctionalUnitType = (source == .flatbed) ? .flatbed : .documentFeeder
        if device.selectedFunctionalUnit.type == wanted { return }
        let available = device.availableFunctionalUnitTypes.map { $0.uintValue }
        guard available.contains(wanted.rawValue) else {
            throw ScanError.unsupported("\(source.rawValue) is not present on this scanner")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingUnit = cont
            device.requestSelect(wanted)
        }
    }

    private func finishOpen(_ result: Result<Void, Error>) {
        guard let cont = pendingOpen else { return }
        pendingOpen = nil
        cont.resume(with: result)
    }
    private func finishUnit(_ result: Result<Void, Error>) {
        guard let cont = pendingUnit else { return }
        pendingUnit = nil
        cont.resume(with: result)
    }
    private func finishScan(_ result: Result<[ScanPage], Error>) {
        guard let cont = pendingScan else { return }
        pendingScan = nil
        cont.resume(with: result)
    }
}

// MARK: - ICDeviceBrowserDelegate

extension ImageCaptureBackend: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice else { return }
        scanner.delegate = self
        let key = scanner.uuidString ?? scanner.name ?? UUID().uuidString
        known[key] = scanner
        if !moreComing { publish() } else { publish() }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let key = device.uuidString ?? device.name ?? ""
        known.removeValue(forKey: key)
        publish()
    }
}

// MARK: - ICScannerDeviceDelegate

extension ImageCaptureBackend: ICScannerDeviceDelegate {

    func didRemove(_ device: ICDevice) {
        let key = device.uuidString ?? device.name ?? ""
        known.removeValue(forKey: key)
        publish()
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { finishOpen(.failure(ScanError.sessionFailed(error.localizedDescription))) }
        else { finishOpen(.success(())) }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) { }

    func deviceDidBecomeReady(_ device: ICDevice) { publish() }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        let wrapped = ScanError.transferFailed(error?.localizedDescription ?? "unknown device error")
        finishOpen(.failure(wrapped))
        finishUnit(.failure(wrapped))
        finishScan(.failure(wrapped))
    }

    func scannerDevice(_ scanner: ICScannerDevice,
                       didSelect functionalUnit: ICScannerFunctionalUnit,
                       error: Error?) {
        if let error { finishUnit(.failure(ScanError.unsupported(error.localizedDescription))) }
        else { finishUnit(.success(())) }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            finishScan(.failure(ScanError.transferFailed("could not decode \(url.lastPathComponent)")))
            return
        }
        let dpi = activeRequest?.resolutionDPI ?? 300
        collectedPages.append(ScanPage(image: image, dpi: dpi, index: collectedPages.count))
        progressHandler?(0.9, "Received page \(collectedPages.count)")
        try? FileManager.default.removeItem(at: url)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteOverviewScanWithError error: Error?) {
        if let error { finishScan(.failure(ScanError.transferFailed(error.localizedDescription))) }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        if isCancelled { finishScan(.failure(ScanError.cancelled)); return }
        if let error {
            finishScan(.failure(ScanError.transferFailed(error.localizedDescription)))
        } else if collectedPages.isEmpty {
            finishScan(.failure(ScanError.transferFailed("scanner reported success but sent no image")))
        } else {
            progressHandler?(1.0, "Done")
            finishScan(.success(collectedPages))
        }
    }
}

// Bridging constant so we do not need to import CoreServices wholesale.
private let kUTTypeTIFF: CFString = "public.tiff" as CFString
