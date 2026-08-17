import Foundation
import SwiftUI
import CoreGraphics
import AppKit
import Combine

struct LogEntry: Identifiable {
    enum Level { case info, warn, error, success }
    let id = UUID()
    let date: Date
    let level: Level
    let text: String
}

@MainActor
final class ScanController: ObservableObject {

    // MARK: Published state

    @Published var settings: ScanSettings {
        didSet { scheduleReprocess(oldValue) }
    }
    @Published private(set) var devices: [ScannerDeviceInfo] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var processedPreview: CGImage?
    @Published private(set) var rawPages: [ScanPage] = []
    @Published private(set) var processedPages: [CGImage] = []
    @Published private(set) var isBusy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var stage: String = "Idle"
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var lastSavedFiles: [URL] = []
    @Published var selectedPageIndex: Int = 0

    /// Bed size for whatever device is selected, defaulting to the DeskJet 2300's A4/Letter platen.
    var bedSizeMM: CGSize {
        selectedDevice?.bedSizeMM ?? CGSize(width: 215.9, height: 297.0)
    }
    var selectedDevice: ScannerDeviceInfo? {
        devices.first { $0.id == selectedDeviceID }
    }
    var availableResolutions: [Int] {
        selectedDevice?.supportedResolutions ?? [75, 100, 150, 200, 300, 600, 1200]
    }
    var availableSources: [ScanSource] {
        selectedDevice?.supportedSources ?? [.flatbed]
    }

    // MARK: Backends

    private let ica = ImageCaptureBackend()
    private let escl = ESCLBackend()
    private let ledm = LEDMBackend()
    private let sim = SimulatedBackend()
    private var icaDevices: [ScannerDeviceInfo] = []
    private var esclDevices: [ScannerDeviceInfo] = []
    private var ledmDevices: [ScannerDeviceInfo] = []
    private var simDevices: [ScannerDeviceInfo] = []

    private var reprocessTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// dpi of whatever is currently sitting in `previewImage` / `rawPages`.
    private var rawDPI: Int = 75
    private var rawWasHardwareCropped = false

    init() {
        settings = ScanSettings.load()
        startDiscovery()
        note("MacScannerX ready. Looking for scanners…", .info)
    }

    // MARK: Discovery

    private func startDiscovery() {
        sim.startDiscovery { [weak self] list in
            Task { @MainActor in self?.simDevices = list; self?.mergeDevices() }
        }
        ica.startDiscovery { [weak self] list in
            Task { @MainActor in
                self?.icaDevices = list
                self?.mergeDevices()
                self?.noteNewHardware(list, transport: "Image Capture")
            }
        }
        escl.startDiscovery { [weak self] list in
            Task { @MainActor in
                self?.esclDevices = list
                self?.mergeDevices()
                self?.noteNewHardware(list, transport: "AirScan")
            }
        }
        ledm.startDiscovery { [weak self] list in
            Task { @MainActor in
                self?.ledmDevices = list
                self?.mergeDevices()
                self?.noteNewHardware(list, transport: "HP LEDM over USB")
            }
        }
    }

    func rescan() {
        note("Re-scanning for devices…", .info)
        ica.stopDiscovery()
        escl.stopDiscovery()
        ledm.stopDiscovery()
        icaDevices = []
        esclDevices = []
        ledmDevices = []
        mergeDevices()
        startDiscovery()
    }

    private func mergeDevices() {
        // Prefer whichever transport can actually acquire. LEDM-over-USB is
        // listed first because on an HP with no ICA driver it is the only path
        // that works; ICA and eSCL entries for the same unit are then dropped.
        var merged = ledmDevices
        for d in icaDevices where !merged.contains(where: { normalized($0.name) == normalized(d.name) }) {
            merged.append(d)
        }
        for d in esclDevices where !merged.contains(where: { normalized($0.name) == normalized(d.name) }) {
            merged.append(d)
        }
        merged += simDevices
        devices = merged

        let selectionIsMissing = selectedDeviceID == nil
            || !merged.contains(where: { $0.id == selectedDeviceID })
        // Drop the simulator once real hardware turns up — but only while the
        // user has not deliberately chosen a device, or every discovery pass
        // would yank them off a scanner they picked on purpose.
        let selectionIsSimulated = selectedDeviceID == SimulatedBackend.deviceID
        let real = merged.first { $0.transport != .simulated }

        if selectionIsMissing || (selectionIsSimulated && real != nil && !userPickedDevice) {
            let deskjet = merged.first {
                $0.name.lowercased().contains("deskjet") && $0.transport != .simulated
            }
            let stored = settings.deviceIdentifier.flatMap { id in
                merged.first { $0.id == id && $0.transport != .simulated }?.id
            }
            selectedDeviceID = stored ?? deskjet?.id ?? real?.id ?? merged.first?.id
        }
        settings.deviceIdentifier = selectedDeviceID
        clampSettingsToDevice()
    }

    private func normalized(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
    }

    private var announced: Set<String> = []
    private func noteNewHardware(_ list: [ScannerDeviceInfo], transport: String) {
        for d in list where !announced.contains(d.id) {
            announced.insert(d.id)
            note("Found \(d.name) via \(transport) [\(d.transport.rawValue)]", .success)
        }
    }

    /// Keep resolution/source legal for whatever is selected.
    private func clampSettingsToDevice() {
        let res = availableResolutions
        if !res.isEmpty, !res.contains(settings.scanResolution) {
            settings.scanResolution = res.min(by: { abs($0 - settings.scanResolution) < abs($1 - settings.scanResolution) })!
        }
        if !res.isEmpty, !res.contains(settings.previewResolution) {
            settings.previewResolution = res.min(by: { abs($0 - 75) < abs($1 - 75) })!
        }
        if !availableSources.contains(settings.source) {
            settings.source = availableSources.first ?? .flatbed
        }
        let bed = bedSizeMM
        if settings.cropSizeMM.width > bed.width { settings.cropSizeMM.width = bed.width }
        if settings.cropSizeMM.height > bed.height { settings.cropSizeMM.height = bed.height }
    }

    /// Set once the user picks a scanner, so automatic re-selection backs off.
    private var userPickedDevice = false

    func selectDevice(_ id: String) {
        userPickedDevice = true
        selectedDeviceID = id
        settings.deviceIdentifier = id
        clampSettingsToDevice()
        note("Selected \(devices.first { $0.id == id }?.name ?? id)", .info)
        Task { await probeSelected() }
    }

    private func probeSelected() async {
        guard let id = selectedDeviceID, let backend = backend(for: id) else { return }
        do {
            let info = try await backend.probe(deviceID: id)
            if let idx = devices.firstIndex(where: { $0.id == id }) {
                devices[idx] = info
            }
            let bed = info.bedSizeMM.map { String(format: "%.0f×%.0f mm", $0.width, $0.height) } ?? "unknown"
            note("Capabilities: bed \(bed), sources \(info.supportedSources.map(\.rawValue).joined(separator: "/")), dpi \(info.supportedResolutions.map(String.init).joined(separator: ","))", .info)
            clampSettingsToDevice()
        } catch {
            note("Probe failed: \(error.localizedDescription)", .warn)
        }
    }

    private func backend(for id: String) -> ScannerBackend? {
        if id == SimulatedBackend.deviceID { return sim }
        if id.hasPrefix("ledm:") { return ledm }
        if id.hasPrefix("escl:") { return escl }
        return ica
    }

    // MARK: Preview / Scan

    func preview() {
        run(isPreview: true)
    }

    func scan() {
        run(isPreview: false)
    }

    private func run(isPreview: Bool) {
        guard !isBusy else { return }
        guard let id = selectedDeviceID, let backend = backend(for: id) else {
            note("No scanner selected.", .error)
            return
        }
        settings.save()

        let area: CGRect
        if isPreview || settings.cropPreset == .maximum || settings.cropPreset == .auto {
            area = CGRect(origin: .zero, size: bedSizeMM)
        } else {
            area = settings.effectiveCropMM
        }
        let dpi = isPreview ? settings.previewResolution : settings.scanResolution
        let hardwareCropped = !(isPreview || settings.cropPreset == .maximum || settings.cropPreset == .auto)

        let request = ScanRequest(
            source: settings.source,
            resolutionDPI: dpi,
            areaMM: area,
            bitDepth: isPreview ? .rgb24 : settings.bitDepth,
            isPreview: isPreview
        )

        isBusy = true
        progress = 0
        stage = isPreview ? "Preview" : "Scan"
        note("\(isPreview ? "Preview" : "Scan") started — \(dpi) dpi, \(String(format: "%.0f×%.0f mm", area.width, area.height)), \(settings.source.rawValue)", .info)

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pages = try await backend.scan(deviceID: id, request: request) { [weak self] p, s in
                    Task { @MainActor in
                        self?.progress = p
                        self?.stage = s
                    }
                }
                await self.ingest(pages: pages, dpi: dpi,
                                  isPreview: isPreview, hardwareCropped: hardwareCropped)
            } catch is CancellationError {
                self.note("Cancelled.", .warn)
            } catch {
                self.note(error.localizedDescription, .error)
            }
            self.isBusy = false
            self.progress = 0
            self.stage = "Idle"
        }
    }

    func cancel() {
        guard isBusy else { return }
        selectedDeviceID.flatMap { backend(for: $0) }?.cancel()
        scanTask?.cancel()
        note("Cancel requested.", .warn)
    }

    private func ingest(pages: [ScanPage], dpi: Int, isPreview: Bool, hardwareCropped: Bool) async {
        rawDPI = dpi
        rawWasHardwareCropped = hardwareCropped

        if isPreview {
            previewImage = pages.first?.image
            note("Preview received: \(pages.first.map { "\($0.image.width)×\($0.image.height) px" } ?? "—")", .success)
            // On a fresh preview with Auto crop, find the document edges.
            if settings.cropPreset == .auto, let img = pages.first?.image {
                autoDetectCrop(in: img, dpi: dpi)
            }
            reprocessNow()
            return
        }

        rawPages = pages
        selectedPageIndex = 0
        note("Scan received: \(pages.count) page\(pages.count == 1 ? "" : "s")", .success)

        stage = "Processing"
        progress = 0.1
        let processed = processAll(pages)
        processedPages = processed
        processedPreview = processed.first
        previewImage = pages.first?.image

        stage = "Saving"
        progress = 0.7
        do {
            let writer = OutputWriter(settings: settings)
            let result = try await writer.write(pages: pages, processed: processed)
            lastSavedFiles = result.files
            for url in result.files { note("Wrote \(url.lastPathComponent)", .success) }
            if result.files.isEmpty { note("No output format is enabled in the Output tab.", .warn) }
            if settings.revealInFinderAfterSave, let first = result.files.first {
                NSWorkspace.shared.activateFileViewerSelecting([first])
            }
        } catch {
            note("Save failed: \(error.localizedDescription)", .error)
        }
        progress = 1.0
    }

    // MARK: Processing

    private func processAll(_ pages: [ScanPage]) -> [CGImage] {
        let pipeline = ImagePipeline(settings: settings, sourceDPI: rawDPI,
                                     cropAlreadyApplied: rawWasHardwareCropped)
        return pages.compactMap { try? pipeline.process($0.image) }
    }

    /// Re-run the pipeline on whatever is on screen when a Filter/Color/Crop
    /// knob moves. Debounced so dragging a slider does not queue a hundred renders.
    private func scheduleReprocess(_ old: ScanSettings) {
        guard old != settings else { return }
        settings.save()
        if old.deviceIdentifier != settings.deviceIdentifier { clampSettingsToDevice() }
        reprocessTask?.cancel()
        reprocessTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.reprocessNow() }
        }
    }

    func reprocessNow() {
        guard let source = rawPages[safe: selectedPageIndex]?.image ?? previewImage else { return }
        let pipeline = ImagePipeline(settings: settings, sourceDPI: rawDPI,
                                     cropAlreadyApplied: rawWasHardwareCropped)
        processedPreview = try? pipeline.process(source)
    }

    /// Re-save the already-scanned pages with the current settings, without
    /// touching the scanner. This is VueScan's "Save" as distinct from "Scan".
    func saveAgain() {
        guard !rawPages.isEmpty else {
            note("Nothing scanned yet — run Scan first.", .warn)
            return
        }
        Task {
            isBusy = true
            stage = "Saving"
            let processed = processAll(rawPages)
            processedPages = processed
            do {
                let writer = OutputWriter(settings: settings)
                let result = try await writer.write(pages: rawPages, processed: processed)
                lastSavedFiles = result.files
                for url in result.files { note("Wrote \(url.lastPathComponent)", .success) }
            } catch {
                note("Save failed: \(error.localizedDescription)", .error)
            }
            isBusy = false
            stage = "Idle"
        }
    }

    // MARK: Auto crop

    /// Finds the non-white bounding box of the preview and converts it to mm.
    /// Same job as VueScan's "Crop size: Auto".
    private func autoDetectCrop(in image: CGImage, dpi: Int) {
        guard let box = DocumentEdgeFinder.contentBounds(of: image) else { return }
        let buffer = settings.autoCropBufferPercent / 100
        var rect = box.insetBy(dx: -box.width * buffer, dy: -box.height * buffer)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        settings.cropOriginMM = CGPoint(
            x: UnitConvert.pixelsToMM(rect.origin.x, dpi: dpi),
            y: UnitConvert.pixelsToMM(rect.origin.y, dpi: dpi)
        )
        settings.cropSizeMM = CGSize(
            width: UnitConvert.pixelsToMM(rect.width, dpi: dpi),
            height: UnitConvert.pixelsToMM(rect.height, dpi: dpi)
        )
        note(String(format: "Auto crop: %.0f×%.0f mm at (%.0f, %.0f)",
                    settings.cropSizeMM.width, settings.cropSizeMM.height,
                    settings.cropOriginMM.x, settings.cropOriginMM.y), .info)
    }

    // MARK: Misc

    func resetSettings() {
        settings = ScanSettings()
        settings.deviceIdentifier = selectedDeviceID
        note("Settings reset to defaults.", .info)
    }

    func note(_ text: String, _ level: LogEntry.Level) {
        log.append(LogEntry(date: Date(), level: level, text: text))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func clearLog() { log.removeAll() }
}

/// Locates the printed area on a scanned page by walking row/column means and
/// finding where they drop away from the paper white.
enum DocumentEdgeFinder {
    static func contentBounds(of image: CGImage, threshold: Double = 0.90) -> CGRect? {
        let maxDim = 800
        let scale = min(1.0, Double(maxDim) / Double(max(image.width, image.height)))
        let w = max(8, Int(Double(image.width) * scale))
        let h = max(8, Int(Double(image.height) * scale))

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let _ = Optional(ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))),
              let data = ctx.data else { return nil }

        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        let cut = UInt8(threshold * 255)

        var minX = w, minY = h, maxX = 0, maxY = 0
        var found = false
        for y in 0..<h {
            for x in 0..<w where px[y * w + x] < cut {
                found = true
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard found, maxX > minX, maxY > minY else { return nil }

        let inv = 1.0 / scale
        // ctx rows run top-down and match CGImage orientation here.
        return CGRect(x: Double(minX) * inv, y: Double(minY) * inv,
                      width: Double(maxX - minX + 1) * inv,
                      height: Double(maxY - minY + 1) * inv)
    }
}
