import Foundation
import CoreGraphics

/// How a device was found. Drives which backend claims it.
enum DeviceTransport: String, Codable {
    case usb = "USB"
    case network = "Network"
    case shared = "Shared"
    case simulated = "Simulated"
}

struct ScannerDeviceInfo: Identifiable, Hashable {
    let id: String              // stable identifier (ICA UUID string, or eSCL base URL)
    let name: String            // "HP DeskJet 2300 series"
    let model: String
    let transport: DeviceTransport
    /// Flatbed bed size in millimetres, once known.
    var bedSizeMM: CGSize?
    var supportedSources: [ScanSource]
    var supportedResolutions: [Int]
    var isReady: Bool

    var displayName: String { "\(name) (\(transport.rawValue))" }
}

/// Everything a backend needs to run one acquisition.
struct ScanRequest {
    var source: ScanSource
    var resolutionDPI: Int
    var areaMM: CGRect          // origin top-left of bed
    var bitDepth: BitDepth
    var isPreview: Bool
    /// Brightness/contrast hints some devices apply in hardware (-100...100 / 0...100).
    var deviceBrightness: Double = 0
    var deviceContrast: Double = 0
}

struct ScanPage {
    let image: CGImage
    let dpi: Int
    let index: Int
}

enum ScanError: LocalizedError {
    case noDeviceSelected
    case deviceUnavailable(String)
    case sessionFailed(String)
    case unsupported(String)
    case transferFailed(String)
    case cancelled
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noDeviceSelected:            return "No scanner selected."
        case .deviceUnavailable(let d):    return "Scanner unavailable: \(d)"
        case .sessionFailed(let d):        return "Could not open a session with the scanner: \(d)"
        case .unsupported(let d):          return "Not supported by this scanner: \(d)"
        case .transferFailed(let d):       return "Image transfer failed: \(d)"
        case .cancelled:                   return "Scan cancelled."
        case .badResponse(let d):          return "Unexpected scanner response: \(d)"
        }
    }
}

/// Progress callback: fraction complete 0...1, plus a human-readable stage.
typealias ScanProgress = @Sendable (Double, String) -> Void

protocol ScannerBackend: AnyObject {
    /// Devices this backend can see right now.
    var devices: [ScannerDeviceInfo] { get }
    /// Start/refresh discovery. Calls `onChange` on the main queue whenever the list moves.
    func startDiscovery(onChange: @escaping ([ScannerDeviceInfo]) -> Void)
    func stopDiscovery()
    /// Interrogate a device for its real capabilities (bed size, sources, resolutions).
    func probe(deviceID: String) async throws -> ScannerDeviceInfo
    /// Acquire one page (or a batch, for feeders).
    func scan(deviceID: String, request: ScanRequest, progress: @escaping ScanProgress) async throws -> [ScanPage]
    func cancel()
}
