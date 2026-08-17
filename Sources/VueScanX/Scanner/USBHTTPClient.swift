import Foundation
import CHPUSB

/// HTTP/1.1 over an HP printer's vendor USB interface.
///
/// The quirks that matter, all learned from a live DeskJet 2300:
///  • the device emits zero-length packets while it is thinking, so a read loop
///    must run on a wall-clock deadline rather than an empty-read count;
///  • every response carries `Connection: close`, so the pipes are drained
///    between requests to stay in sync;
///  • bodies come back chunked far more often than with `Content-Length`.
final class USBHTTPClient {

    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers[name.lowercased()]
        }
        var text: String { String(decoding: body, as: UTF8.self) }
    }

    enum ClientError: LocalizedError {
        case cannotOpen(Int32)
        case writeFailed
        case readFailed
        case noResponse
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let code):
                return "Could not claim the printer's USB interface (IOReturn 0x\(String(format: "%08x", UInt32(bitPattern: code)))). Another program may be using the scanner."
            case .writeFailed:      return "USB write failed."
            case .readFailed:       return "USB read failed."
            case .noResponse:       return "The scanner did not respond."
            case .malformed(let d): return "Malformed HTTP response: \(d)"
            }
        }
    }

    private var handle: OpaquePointer?
    private let locationID: UInt32
    /// How long a pre-request drain may spend clearing stale bytes. Discovery
    /// uses a small budget so it never stalls the device list; a scan uses a
    /// large one because an abandoned page can be megabytes.
    var drainBudget: TimeInterval

    init(locationID: UInt32, drainBudget: TimeInterval = 6) throws {
        self.locationID = locationID
        self.drainBudget = drainBudget
        var err: Int32 = 0
        guard let h = hpusb_open(locationID, &err) else {
            throw ClientError.cannotOpen(err)
        }
        handle = h
    }

    deinit { close() }

    func close() {
        if let handle {
            hpusb_close(handle)
            self.handle = nil
        }
    }

    private var raw: OpaquePointer? { handle }

    // MARK: Requests

    func get(_ path: String, timeout: TimeInterval = 15) throws -> Response {
        try request(method: "GET", path: path, timeout: timeout)
    }

    func post(_ path: String, body: Data, contentType: String = "text/xml",
              timeout: TimeInterval = 30) throws -> Response {
        try request(method: "POST", path: path, body: body,
                    contentType: contentType, timeout: timeout)
    }

    func delete(_ path: String, timeout: TimeInterval = 10) throws -> Response {
        try request(method: "DELETE", path: path, timeout: timeout)
    }

    /// Discards anything the device is still pushing from an abandoned
    /// exchange. Returns the number of stale bytes dropped.
    @discardableResult
    func resync(budget: TimeInterval = 20) -> Int {
        guard let raw else { return 0 }
        let stale = Int(hpusb_drain(raw, UInt32(budget * 1000)))
        hpusb_reset_pipes(raw)
        return stale
    }

    /// Last resort when the printer's own HTTP server has stopped answering:
    /// a USB reset. The handle is dead afterwards, so callers must reopen.
    @discardableResult
    func resetDevice() -> Bool {
        guard let raw else { return false }
        return hpusb_reset_device(raw) == 0
    }

    /// One retry after a hard resync: a request that lands while the device is
    /// still flushing an abandoned page gets no reply, but succeeds once the
    /// pipe is clean.
    func request(method: String, path: String, body: Data? = nil,
                 contentType: String = "text/xml",
                 timeout: TimeInterval = 15,
                 allowRetry: Bool = true) throws -> Response {
        do {
            return try sendOnce(method: method, path: path, body: body,
                                contentType: contentType, timeout: timeout)
        } catch ClientError.noResponse where allowRetry {
            resync(budget: 20)
            return try sendOnce(method: method, path: path, body: body,
                                contentType: contentType, timeout: timeout)
        }
    }

    private func sendOnce(method: String, path: String, body: Data?,
                          contentType: String,
                          timeout: TimeInterval) throws -> Response {
        guard let raw else { throw ClientError.cannotOpen(0) }

        // Location headers come back absolute (http://localhost:0/Jobs/...);
        // reduce to a path so the request line is well formed.
        let target = Self.pathComponent(of: path)

        var head = "\(method) \(target) HTTP/1.1\r\n"
        head += "Host: localhost\r\n"
        head += "User-Agent: VueScanX/1.0\r\n"
        head += "Accept: */*\r\n"
        head += "Connection: close\r\n"
        if let body {
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"

        // Exits as soon as the pipe is quiet, so this is cheap in the normal case.
        hpusb_drain(raw, UInt32(drainBudget * 1000))

        var packet = Data(head.utf8)
        if let body { packet.append(body) }

        var written = packet.withUnsafeBytes { buf -> Int32 in
            hpusb_write(raw, buf.baseAddress, UInt32(buf.count), 8000)
        }
        if written < 0 {
            // Almost always a data-toggle mismatch left by an abandoned
            // transfer; re-syncing the pipes makes the retry succeed.
            hpusb_reset_pipes(raw)
            written = packet.withUnsafeBytes { buf -> Int32 in
                hpusb_write(raw, buf.baseAddress, UInt32(buf.count), 8000)
            }
        }
        guard written >= 0 else { throw ClientError.writeFailed }

        let data = try readResponse(timeout: timeout)
        guard !data.isEmpty else { throw ClientError.noResponse }
        return try Self.parse(data)
    }

    // MARK: Reading

    private func readResponse(timeout: TimeInterval) throws -> Data {
        guard let raw else { throw ClientError.readFailed }
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        var headerEnd: Int? = nil
        var contentLength: Int? = nil
        var chunked = false
        var deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let n = buffer.withUnsafeMutableBytes { buf -> Int32 in
                hpusb_read(raw, buf.baseAddress, UInt32(buf.count), 500)
            }
            if n < 0 {
                if accumulated.isEmpty { throw ClientError.readFailed }
                break
            }
            if n == 0 { continue }  // zero-length packet: still working

            accumulated.append(contentsOf: buffer[0..<Int(n)])
            // Any progress resets the clock; a 600 dpi page takes a while.
            deadline = Date().addingTimeInterval(timeout)

            if headerEnd == nil, let range = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.upperBound
                let headerText = String(decoding: accumulated[..<range.lowerBound], as: UTF8.self)
                for line in headerText.components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        contentLength = Int(line.dropFirst("content-length:".count)
                            .trimmingCharacters(in: .whitespaces))
                    }
                    if lower.hasPrefix("transfer-encoding:"), lower.contains("chunked") {
                        chunked = true
                    }
                }
            }

            if let end = headerEnd {
                if let length = contentLength, accumulated.count - end >= length { break }
                if chunked, accumulated.range(of: Data("\r\n0\r\n\r\n".utf8), in: end..<accumulated.count) != nil {
                    break
                }
                if !chunked, contentLength == nil, accumulated.count > end { break }
                if !chunked, contentLength == 0 { break }
            }
        }
        return accumulated
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> Response {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw ClientError.malformed("no header terminator")
        }
        let headerText = String(decoding: data[..<sep.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first,
              let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") else {
            throw ClientError.malformed("bad status line")
        }
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        var body = data[sep.upperBound...]
        if headers["transfer-encoding"]?.contains("chunked") == true {
            body = Self.dechunk(body)[...]
        } else if let length = headers["content-length"].flatMap(Int.init) {
            body = body.prefix(length)
        }
        return Response(status: status, headers: headers, body: Data(body))
    }

    static func dechunk(_ input: Data) -> Data {
        var out = Data()
        var index = input.startIndex
        let crlf = Data("\r\n".utf8)

        while index < input.endIndex {
            guard let lineEnd = input.range(of: crlf, in: index..<input.endIndex) else { break }
            let sizeText = String(decoding: input[index..<lineEnd.lowerBound], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            // Chunk extensions after ';' are legal and must be ignored.
            let sizeToken = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(sizeToken, radix: 16) else { break }
            if size == 0 { break }

            let start = lineEnd.upperBound
            let end = input.index(start, offsetBy: size, limitedBy: input.endIndex) ?? input.endIndex
            out.append(input[start..<end])
            // Skip the chunk's trailing CRLF.
            index = input.index(end, offsetBy: 2, limitedBy: input.endIndex) ?? input.endIndex
        }
        return out
    }

    /// `http://localhost:0/Jobs/JobList/1` → `/Jobs/JobList/1`
    static func pathComponent(of location: String) -> String {
        if location.hasPrefix("/") { return location }
        if let url = URL(string: location), url.scheme != nil {
            let path = url.path
            return path.isEmpty ? "/" : path
        }
        return "/" + location
    }
}
