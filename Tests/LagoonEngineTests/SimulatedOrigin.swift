import Foundation

/// The link between the engine and a `SimulatedOrigin`.
nonisolated struct SimulatedLink: Sendable {
    /// Every response's headers arrive this long after the request.
    var roundTrip: TimeInterval = 0
    /// Shared by every body in flight. Nil is unlimited.
    var bytesPerSecond: Double?
}

/// What one path does wrong.
nonisolated enum SimulatedFault: Sendable {
    /// Answers every request with this status and no body.
    case status(Int)
    /// Answers the first `times` requests with this status, then serves.
    case statusFirst(Int, times: Int)
    /// Delivers the body at this rate, however fast the link.
    case trickle(bytesPerSecond: Double)
    /// Loses the connection once, partway through the body of the first
    /// request that spans this byte of the file.
    case dropOnce(atByte: Int)
    /// Loses the connection once, straight after the headers, on the first
    /// request that starts at or past this byte of the file.
    case dropAfterHeadersOnce(fromByte: Int)
}

/// A media server at the far end of a modelled link, for driving the cache,
/// the fill and the HLS path end to end. Honours `Range`, waits a round trip
/// before each response, paces bodies through the link's shared bandwidth,
/// and applies each path's fault.
nonisolated final class SimulatedOrigin: URLProtocol, @unchecked Sendable {
    static let host = "origin.test"

    private struct Resource {
        var body: Data
        var fault: SimulatedFault?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var link = SimulatedLink()
    private nonisolated(unsafe) static var resources: [String: Resource] = [:]
    private nonisolated(unsafe) static var recorded: [String: [String?]] = [:]
    private nonisolated(unsafe) static var answered: [String: Int] = [:]
    private nonisolated(unsafe) static var dropped: Set<String> = []
    /// When the link is next free, so concurrent bodies share it.
    private nonisolated(unsafe) static var linkFreeAt: TimeInterval = 0
    private nonisolated(unsafe) static var bodyBytes = 0
    private nonisolated(unsafe) static var bodySeconds: TimeInterval = 0

    private static let chunkSize = 64 * 1_024
    private let stateLock = NSLock()
    private var stopped = false

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimulatedOrigin.self]
        return configuration
    }

    static func reset(link: SimulatedLink = SimulatedLink()) {
        lock.withLock {
            self.link = link
            resources = [:]
            recorded = [:]
            answered = [:]
            dropped = []
            linkFreeAt = 0
            bodyBytes = 0
            bodySeconds = 0
        }
    }

    static func serve(_ path: String, body: Data, fault: SimulatedFault? = nil) {
        lock.withLock { resources[path] = Resource(body: body, fault: fault) }
    }

    static func url(_ path: String) -> URL {
        URL(string: "https://\(host)\(path)")!
    }

    /// What the bodies sent so far took, from headers to last byte. A loaded
    /// machine delivers below the link's rate, so compare against this.
    static var deliveredBytesPerSecond: Double? {
        lock.withLock { bodySeconds > 0 ? Double(bodyBytes) / bodySeconds : nil }
    }

    /// The `Range` header of each request for the path, in order.
    static func requests(path: String) -> [String?] {
        lock.withLock { recorded[path] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let range = request.value(forHTTPHeaderField: "Range")
        let (resource, link, attempt) = Self.lock.withLock {
            Self.recorded[url.path, default: []].append(range)
            let attempt = Self.answered[url.path, default: 0]
            Self.answered[url.path] = attempt + 1
            return (Self.resources[url.path], Self.link, attempt)
        }
        // Off URLSession's loading thread, which `stopLoading` also needs.
        DispatchQueue.global().async { [self] in
            Thread.sleep(forTimeInterval: link.roundTrip)
            guard !isStopped else { return }
            respond(url: url, range: range, resource: resource, attempt: attempt)
        }
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }

    private var isStopped: Bool {
        stateLock.withLock { stopped }
    }

    private func respond(url: URL, range: String?, resource: Resource?, attempt: Int) {
        guard let resource else {
            answer(url: url, status: 404)
            return
        }
        switch resource.fault {
        case .status(let code):
            answer(url: url, status: code)
            return
        case .statusFirst(let code, let times) where attempt < times:
            answer(url: url, status: code)
            return
        default:
            break
        }
        let total = resource.body.count
        guard let (lower, upper) = Self.bounds(range, total: total) else {
            answer(url: url, status: 416, headers: ["Content-Range": "bytes */\(total)"])
            return
        }
        let ranged = range != nil
        answer(url: url, status: ranged ? 206 : 200, headers: [
            "Content-Length": "\(upper - lower)",
        ].merging(ranged ? ["Content-Range": "bytes \(lower)-\(upper - 1)/\(total)"] : [:]) { $1 }, finish: false)
        var dropAfter: Int?
        switch resource.fault {
        case .dropOnce(let byte) where lower < byte && byte < upper:
            dropAfter = byte - lower
        case .dropAfterHeadersOnce(let byte) where lower >= byte:
            dropAfter = 0
        default:
            break
        }
        if dropAfter != nil, !Self.markDropped(url.path) { dropAfter = nil }
        stream(resource.body.subdata(in: lower..<upper), dropAfter: dropAfter, fault: resource.fault)
    }

    private func stream(_ body: Data, dropAfter: Int?, fault: SimulatedFault?) {
        let started = ProcessInfo.processInfo.systemUptime
        var sent = 0
        defer {
            let seconds = ProcessInfo.processInfo.systemUptime - started
            Self.lock.withLock {
                Self.bodyBytes += sent
                Self.bodySeconds += seconds
            }
        }
        while sent < body.count {
            if isStopped { return }
            if let dropAfter, sent >= dropAfter {
                // URLSession can hand over a protocol's error ahead of the
                // bytes sent just before it. A socket never does.
                if sent > 0 { Thread.sleep(forTimeInterval: 0.05) }
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            var count = min(Self.chunkSize, body.count - sent)
            if let dropAfter {
                count = min(count, dropAfter - sent)
            }
            let chunk = body.subdata(in: sent..<(sent + count))
            Self.waitForLink(bytes: count, trickle: fault)
            if isStopped { return }
            client?.urlProtocol(self, didLoad: chunk)
            sent += count
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func answer(url: URL, status: Int, headers: [String: String] = [:], finish: Bool = true) {
        let fields = ["Content-Type": "application/octet-stream"].merging(headers) { $1 }
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!,
            cacheStoragePolicy: .notAllowed
        )
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }

    /// Holds a chunk until the link, or the path's trickle, could have carried it.
    private static func waitForLink(bytes: Int, trickle fault: SimulatedFault?) {
        if case .trickle(let rate) = fault {
            Thread.sleep(forTimeInterval: Double(bytes) / rate)
            return
        }
        let departure: TimeInterval? = lock.withLock {
            guard let rate = link.bytesPerSecond else { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            // A sleep overshoots by a little each chunk. Within a moment's lag
            // the link is still busy, not idle, so the schedule holds.
            let busySince = now - linkFreeAt < 0.05 ? linkFreeAt : now
            linkFreeAt = busySince + Double(bytes) / rate
            return linkFreeAt
        }
        guard let departure else { return }
        let wait = departure - ProcessInfo.processInfo.systemUptime
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    private static func markDropped(_ path: String) -> Bool {
        lock.withLock { dropped.insert(path).inserted }
    }

    /// `bytes=a-b` or `bytes=a-`, clamped to the body; nil past its end.
    private static func bounds(_ range: String?, total: Int) -> (Int, Int)? {
        guard let range else { return (0, total) }
        guard range.hasPrefix("bytes=") else { return nil }
        let parts = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, let lower = Int(first), lower < total else { return nil }
        let upper = parts.count > 1 ? Int(parts[1]).map { min($0 + 1, total) } ?? total : total
        return upper > lower ? (lower, upper) : nil
    }
}
