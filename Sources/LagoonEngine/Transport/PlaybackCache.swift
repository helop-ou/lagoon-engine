import Foundation

/// Chooses where Lagoon may safely put a cache in the playback path. Direct
/// files have one stable, seekable resource and can use the sparse AVIO cache.
/// A Jellyfin HLS transcode has mutable manifests and stays on libavformat's
/// native transport unless the diagnostic switch is on.
///
/// That leaves a transcode with no buffering whatsoever between the network
/// and the renderers: any hitch in segment delivery drains
/// both demux queues, and audio, having no cushion, goes silent at once.
/// Whether turning this on fixes that is the open question the switch exists
/// to answer.
nonisolated enum PlaybackBufferPolicy {
    static let backgroundBufferingEnabled = true

    static func customIOEnabled(
        for method: PlayMethod,
        defaults: UserDefaults = .standard
    ) -> Bool {
        switch method {
        case .directPlay, .directStream:
            true
        case .transcode:
            // Off by default, so a build nobody has touched behaves exactly
            // as before. It is readable in Release rather than DEBUG-only
            // because the only hardware that can answer whether this helps is
            // an Apple TV, and pairing one to Xcode costs it HDCP 2.2 until
            // it is unpaired again — so a debug build is not a thing that can
            // be run there in practice. Settings, Playback Diagnostics
            // exposes the switch alongside the HUD.
            defaults.bool(forKey: "debug.experimentalPlaybackCache")
        }
    }

    /// Whether the engine is handed the cache session at all. A complete
    /// cache file is played straight from disk, so the session would only
    /// add a layer, except for a disc image: the demuxer mounts a disc
    /// through the session's byte source and cannot read the image from a
    /// plain file, so without the session a fully cached disc fell to the
    /// server remux the session exists to avoid.
    static func engineUsesCacheSession(
        playsFromCompleteFile: Bool,
        disc: Bool,
        method: PlayMethod,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard customIOEnabled(for: method, defaults: defaults) else { return false }
        return disc || !playsFromCompleteFile
    }
}

/// A half-open byte interval stored in a playback cache file.
nonisolated struct PlaybackByteRange: Equatable, Sendable {
    let lowerBound: Int64
    let upperBound: Int64

    init(_ lowerBound: Int64, _ upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = max(upperBound, lowerBound)
    }

    var count: Int64 { upperBound - lowerBound }

    func contains(_ other: PlaybackByteRange) -> Bool {
        lowerBound <= other.lowerBound && upperBound >= other.upperBound
    }
}

/// Sorted, coalesced ranges. Keeping this logic independent from file and
/// network I/O makes cache accounting and cap enforcement deterministic.
nonisolated struct PlaybackByteRangeSet: Equatable, Sendable {
    private(set) var ranges: [PlaybackByteRange] = []

    var byteCount: Int64 { ranges.reduce(0) { $0 + $1.count } }

    /// End of the uninterrupted cached prefix. Only this prefix is safe to
    /// draw as a single buffered timeline range or promote as a whole file.
    var contiguousUpperBound: Int64 {
        guard let first = ranges.first, first.lowerBound == 0 else { return 0 }
        return first.upperBound
    }

    func contains(_ range: PlaybackByteRange) -> Bool {
        ranges.contains { $0.contains(range) }
    }

    /// End of the cached island that holds `offset`, or `offset` itself when
    /// that byte is not cached. The scheduler reads this at the playhead to
    /// know how far ahead playback can run without touching the network.
    func contiguousUpperBound(from offset: Int64) -> Int64 {
        for range in ranges where range.lowerBound <= offset {
            if range.upperBound > offset { return range.upperBound }
        }
        return offset
    }

    /// Returns the first hole at or after `offset`, bounded by both the
    /// caller's scheduling window and the next cached island. Proactive
    /// buffering uses this instead of blindly extending the byte-zero
    /// prefix so a foreground seek can move its work to the new playhead
    /// without redownloading or discarding any earlier ranges.
    func firstUncachedRange(
        startingAt offset: Int64,
        endingBefore upperBound: Int64,
        maximumCount: Int64
    ) -> PlaybackByteRange? {
        guard maximumCount > 0, upperBound > 0 else { return nil }
        var cursor = min(max(offset, 0), upperBound)
        guard cursor < upperBound else { return nil }

        for range in ranges {
            if range.upperBound <= cursor { continue }
            if range.lowerBound > cursor {
                let end = min(upperBound, min(range.lowerBound, cursor + maximumCount))
                return end > cursor ? PlaybackByteRange(cursor, end) : nil
            }
            cursor = max(cursor, range.upperBound)
            if cursor >= upperBound { return nil }
        }

        let end = min(upperBound, cursor + maximumCount)
        return end > cursor ? PlaybackByteRange(cursor, end) : nil
    }

    @discardableResult
    mutating func insert(_ range: PlaybackByteRange) -> Int64 {
        guard range.count > 0 else { return 0 }
        let before = byteCount
        var merged = range
        var output: [PlaybackByteRange] = []
        var didInsert = false

        for existing in ranges {
            if existing.upperBound < merged.lowerBound {
                output.append(existing)
            } else if merged.upperBound < existing.lowerBound {
                if !didInsert {
                    output.append(merged)
                    didInsert = true
                }
                output.append(existing)
            } else {
                merged = PlaybackByteRange(
                    min(merged.lowerBound, existing.lowerBound),
                    max(merged.upperBound, existing.upperBound)
                )
            }
        }
        if !didInsert { output.append(merged) }
        ranges = output
        return byteCount - before
    }

    /// Drops a byte interval, splitting any island it lands inside. Eviction
    /// is the only caller: a windowed cache has to give bytes back before it
    /// can take new ones, and `ranges` is the sole authority on what a read
    /// may take from the file, so a removed interval is immediately a miss
    /// rather than a hole that could be read back as zeros.
    @discardableResult
    mutating func remove(_ range: PlaybackByteRange) -> Int64 {
        guard range.count > 0 else { return 0 }
        let before = byteCount
        var output: [PlaybackByteRange] = []
        for existing in ranges {
            if existing.upperBound <= range.lowerBound || existing.lowerBound >= range.upperBound {
                output.append(existing)
                continue
            }
            if existing.lowerBound < range.lowerBound {
                output.append(PlaybackByteRange(existing.lowerBound, range.lowerBound))
            }
            if existing.upperBound > range.upperBound {
                output.append(PlaybackByteRange(range.upperBound, existing.upperBound))
            }
        }
        ranges = output
        return before - byteCount
    }
}

/// A sparse cached byte island normalized onto the player timeline. Direct
/// files can contain several of these after a seek; presenting all of them
/// avoids pretending that only the uninterrupted byte-zero prefix survived.
nonisolated struct PlaybackBufferedRange: Equatable, Hashable, Sendable {
    let lowerFraction: Double
    let upperFraction: Double
}

/// The container byte position FFmpeg selected for a known media time.
/// Direct files are commonly variable bitrate, so this anchor is required
/// to project sparse byte ranges onto the scrubber without putting the hot
/// cache island visibly ahead of (or behind) the playhead.
nonisolated struct PlaybackTimelineAnchor: Equatable, Sendable {
    let byteOffset: Int64
    let timeFraction: Double
}

nonisolated struct PlaybackCacheMetrics: Equatable, Sendable {
    let cachedBytes: Int64
    let networkBytes: Int64
    let cacheHitBytes: Int64
    let requestCount: Int
    let networkRequestSeconds: Double
    let evictionCount: Int
    let resourceCount: Int
    let capacityBytes: Int64
    let contiguousCachedBytes: Int64
    let contentLength: Int64?
    let cachedByteRanges: [PlaybackByteRange]
    let playheadPrefetchCount: Int
    let timelineAnchor: PlaybackTimelineAnchor?
    /// True when the title is larger than the cap, so the cache holds a
    /// window that travels with the playhead instead of accumulating the
    /// whole file. Proactive fill never finishes in that mode.
    let isWindowed: Bool
    /// Cached bytes contiguous from the most recent foreground read onward:
    /// the cushion the fill scheduler protects.
    let cachedBytesAheadOfPlayhead: Int64
    /// Bytes downloaded that were already on disk when they arrived — the
    /// cost of a foreground read overtaking a prefetch of the same range.
    let duplicateNetworkBytes: Int64
    /// Foreground reads that waited for an in-flight prefetch of their
    /// bytes instead of downloading them again.
    let sharedFetchCount: Int

    init(
        cachedBytes: Int64,
        networkBytes: Int64,
        cacheHitBytes: Int64,
        requestCount: Int,
        networkRequestSeconds: Double,
        evictionCount: Int = 0,
        resourceCount: Int = 0,
        capacityBytes: Int64 = 0,
        contiguousCachedBytes: Int64 = 0,
        contentLength: Int64? = nil,
        cachedByteRanges: [PlaybackByteRange] = [],
        playheadPrefetchCount: Int = 0,
        timelineAnchor: PlaybackTimelineAnchor? = nil,
        isWindowed: Bool = false,
        cachedBytesAheadOfPlayhead: Int64 = 0,
        duplicateNetworkBytes: Int64 = 0,
        sharedFetchCount: Int = 0
    ) {
        self.cachedBytes = cachedBytes
        self.networkBytes = networkBytes
        self.cacheHitBytes = cacheHitBytes
        self.requestCount = requestCount
        self.networkRequestSeconds = networkRequestSeconds
        self.evictionCount = evictionCount
        self.resourceCount = resourceCount
        self.capacityBytes = capacityBytes
        self.contiguousCachedBytes = contiguousCachedBytes
        self.contentLength = contentLength
        self.cachedByteRanges = cachedByteRanges
        self.playheadPrefetchCount = playheadPrefetchCount
        self.timelineAnchor = timelineAnchor
        self.isWindowed = isWindowed
        self.cachedBytesAheadOfPlayhead = cachedBytesAheadOfPlayhead
        self.duplicateNetworkBytes = duplicateNetworkBytes
        self.sharedFetchCount = sharedFetchCount
    }

    var bufferedFraction: Double? {
        guard let contentLength, contentLength > 0 else { return nil }
        return min(max(Double(contiguousCachedBytes) / Double(contentLength), 0), 1)
    }

    var bufferedRanges: [PlaybackBufferedRange] {
        guard let contentLength, contentLength > 0 else { return [] }
        return cachedByteRanges.compactMap { range in
            let lower = timelineFraction(for: range.lowerBound, contentLength: contentLength)
            let upper = timelineFraction(for: range.upperBound, contentLength: contentLength)
            guard upper > lower else { return nil }
            return PlaybackBufferedRange(lowerFraction: lower, upperFraction: upper)
        }
    }

    /// Piecewise-linear projection through the most recent timeline anchor.
    /// byte-to-time relationship is still an estimate between known points,
    /// but the active playhead itself is exact and both file boundaries stay
    /// pinned to 0 and 1.
    private func timelineFraction(for byteOffset: Int64, contentLength: Int64) -> Double {
        let byteOffset = min(max(byteOffset, 0), contentLength)
        guard let timelineAnchor,
              timelineAnchor.byteOffset > 0,
              timelineAnchor.byteOffset < contentLength,
              timelineAnchor.timeFraction > 0,
              timelineAnchor.timeFraction < 1 else {
            return Double(byteOffset) / Double(contentLength)
        }

        if byteOffset <= timelineAnchor.byteOffset {
            return timelineAnchor.timeFraction
                * Double(byteOffset)
                / Double(timelineAnchor.byteOffset)
        }
        return timelineAnchor.timeFraction
            + (1 - timelineAnchor.timeFraction)
                * Double(byteOffset - timelineAnchor.byteOffset)
                / Double(contentLength - timelineAnchor.byteOffset)
    }

    var hitRate: Double {
        let total = cacheHitBytes + networkBytes
        return total > 0 ? Double(cacheHitBytes) / Double(total) : 0
    }

    var averageRequestMilliseconds: Double {
        requestCount > 0 ? networkRequestSeconds * 1_000 / Double(requestCount) : 0
    }

    static let zero = PlaybackCacheMetrics(
        cachedBytes: 0,
        networkBytes: 0,
        cacheHitBytes: 0,
        requestCount: 0,
        networkRequestSeconds: 0,
        evictionCount: 0,
        resourceCount: 0,
        capacityBytes: 0
    )

    func adding(_ other: PlaybackCacheMetrics, includeCachedBytes: Bool = true) -> PlaybackCacheMetrics {
        PlaybackCacheMetrics(
            cachedBytes: cachedBytes + (includeCachedBytes ? other.cachedBytes : 0),
            networkBytes: networkBytes + other.networkBytes,
            cacheHitBytes: cacheHitBytes + other.cacheHitBytes,
            requestCount: requestCount + other.requestCount,
            networkRequestSeconds: networkRequestSeconds + other.networkRequestSeconds,
            evictionCount: evictionCount + other.evictionCount,
            resourceCount: resourceCount + other.resourceCount,
            capacityBytes: capacityBytes + other.capacityBytes,
            contiguousCachedBytes: contiguousCachedBytes + other.contiguousCachedBytes,
            contentLength: nil,
            playheadPrefetchCount: playheadPrefetchCount + other.playheadPrefetchCount,
            timelineAnchor: nil,
            isWindowed: isWindowed || other.isWindowed
        )
    }

    func reporting(evictionCount: Int, resourceCount: Int, capacityBytes: Int64) -> PlaybackCacheMetrics {
        PlaybackCacheMetrics(
            cachedBytes: cachedBytes,
            networkBytes: networkBytes,
            cacheHitBytes: cacheHitBytes,
            requestCount: requestCount,
            networkRequestSeconds: networkRequestSeconds,
            evictionCount: evictionCount,
            resourceCount: resourceCount,
            capacityBytes: capacityBytes,
            contiguousCachedBytes: contiguousCachedBytes,
            contentLength: contentLength,
            cachedByteRanges: cachedByteRanges,
            playheadPrefetchCount: playheadPrefetchCount,
            timelineAnchor: timelineAnchor,
            isWindowed: isWindowed
        )
    }
}

/// Shared accounting for caches made of multiple sparse files. Reservations
/// happen before a write, so aggregate stored bytes cannot cross the cap even
/// when FFmpeg opens or prefetches several HLS resources concurrently.
nonisolated final class PlaybackCacheStorageBudget: @unchecked Sendable {
    private let byteLimit: Int64
    private let lock = NSLock()
    private var usedBytes: Int64 = 0

    init(byteLimit: Int64) {
        self.byteLimit = max(byteLimit, 0)
    }

    var availableBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return max(byteLimit - usedBytes, 0)
    }

    func reserve(upTo byteCount: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let reserved = min(max(byteCount, 0), max(byteLimit - usedBytes, 0))
        usedBytes += reserved
        return reserved
    }

    func release(_ byteCount: Int64) {
        lock.lock()
        usedBytes = max(usedBytes - max(byteCount, 0), 0)
        lock.unlock()
    }
}

nonisolated struct PlaybackRangeResponse: Sendable {
    let data: Data
    let offset: Int64
    let totalLength: Int64?
    let transferredBytes: Int64

    init(data: Data, offset: Int64, totalLength: Int64?, transferredBytes: Int64? = nil) {
        self.data = data
        self.offset = offset
        self.totalLength = totalLength
        self.transferredBytes = transferredBytes ?? Int64(data.count)
    }
}

nonisolated protocol PlaybackRangeLoading: AnyObject, Sendable {
    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse
    func cancelAll()
    /// A foreground read has caught up with an in-flight low-priority
    /// request for `range`: finish it at foreground priority rather than
    /// letting a second request for the same bytes race it.
    /// Optional for loaders that have no priority to raise.
    func promote(range: PlaybackByteRange)
}

extension PlaybackRangeLoading {
    func promote(range: PlaybackByteRange) {}
}

/// What one proactive fetch did. The scheduler needs to tell a fetch that
/// failed (and should be retried after a backoff) from one that found
/// nothing left to fetch (the file is complete under the cap, or the
/// window is full); a Boolean collapsed both into "stop".
nonisolated enum PlaybackPrefetchOutcome: Equatable, Sendable {
    /// A chunk landed: the bytes the request returned and how long that one
    /// request took, so pacing measures the prefetch itself rather than the
    /// cache's aggregate including foreground traffic.
    case fetched(bytes: Int, seconds: Double)
    case exhausted
    case failed
    case cancelled

    var advanced: Bool {
        if case .fetched = self { return true }
        return false
    }
}

nonisolated enum PlaybackCacheError: LocalizedError {
    case cancelled
    case invalidResponse
    case rangeUnsupported
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .cancelled: "Playback caching was cancelled."
        case .invalidResponse: "The media server returned an invalid byte-range response."
        case .rangeUnsupported: "The media server does not support the requested byte range."
        case .storageUnavailable: "The playback cache could not be opened."
        }
    }
}

/// A bounded streaming range request. A server that ignores `Range` cannot
/// back a seekable sparse file: accepting its 200 response would repeatedly
/// redownload and discard the prefix as buffering advances. Reject it before
/// body delivery so the engine can retry through native libavformat instead.
nonisolated private final class PlaybackRangeRequest: @unchecked Sendable {
    let urlRequest: URLRequest
    private let requestedRange: PlaybackByteRange
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var received = Data()
    private var transferredBytes: Int64 = 0
    private var result: Result<PlaybackRangeResponse, Error>?
    private let taskPriority: Float

    init(
        url: URL,
        range: PlaybackByteRange,
        priority: Float,
        authorization: MediaRequestAuthorization? = nil
    ) {
        requestedRange = range
        taskPriority = priority
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue(
            "bytes=\(range.lowerBound)-\(max(range.upperBound - 1, range.lowerBound))",
            forHTTPHeaderField: "Range"
        )
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if priority <= URLSessionTask.lowPriority {
            // Proactive fill must never consume metered/Low Data Mode paths.
            // Foreground playback remains allowed and wins independently.
            request.allowsExpensiveNetworkAccess = false
            request.allowsConstrainedNetworkAccess = false
        }
        // Strips any query-string token and sets the Authorization header,
        // but only for the Jellyfin origin — an HLS child playlist or
        // segment can be server-generated and point elsewhere entirely.
        authorization?.apply(to: &request)
        urlRequest = request
    }

    func attach(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        lock.unlock()
        task.priority = taskPriority
    }

    var range: PlaybackByteRange { requestedRange }

    func promote() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.priority = URLSessionTask.highPriority
    }

    func waitForResult() throws -> PlaybackRangeResponse {
        completion.wait()
        lock.lock()
        let result = result ?? .failure(PlaybackCacheError.cancelled)
        self.task = nil
        lock.unlock()
        return try result.get()
    }

    func cancel() {
        finish(.failure(PlaybackCacheError.cancelled), cancelTask: true)
    }

    func receive(
        response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(PlaybackCacheError.invalidResponse), cancelTask: true)
            return
        }
        let validPartial = http.statusCode == 206
            && Self.responseOffset(response: http) == requestedRange.lowerBound
        guard validPartial else {
            completionHandler(.cancel)
            finish(.failure(PlaybackCacheError.rangeUnsupported), cancelTask: true)
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func receive(data: Data) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        transferredBytes += Int64(data.count)
        let remaining = max(Int(requestedRange.count) - received.count, 0)
        if remaining > 0 {
            received.append(data.prefix(remaining))
        }
        let complete = received.count >= Int(requestedRange.count)
        lock.unlock()
        if complete {
            finishCurrentResponse(cancelTask: true)
        }
    }

    func complete(error: Error?) {
        lock.lock()
        let hasResponse = response != nil
        lock.unlock()
        if hasResponse {
            finishCurrentResponse(cancelTask: false)
        } else {
            finish(.failure(error ?? PlaybackCacheError.invalidResponse), cancelTask: false)
        }
    }

    private func finishCurrentResponse(cancelTask: Bool) {
        lock.lock()
        guard result == nil, let response else {
            lock.unlock()
            return
        }
        let data = received
        let totalLength = Self.totalLength(response: response, requestedRange: requestedRange)
        let totalTransferredBytes = self.transferredBytes
        let offset = Self.responseOffset(response: response) ?? requestedRange.lowerBound
        lock.unlock()
        finish(.success(PlaybackRangeResponse(
            data: data,
            offset: offset,
            totalLength: totalLength,
            transferredBytes: totalTransferredBytes
        )), cancelTask: cancelTask)
    }

    private func finish(_ newResult: Result<PlaybackRangeResponse, Error>, cancelTask: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = newResult
        let task = self.task
        lock.unlock()
        if cancelTask { task?.cancel() }
        completion.signal()
    }

    private static func totalLength(
        response: HTTPURLResponse,
        requestedRange: PlaybackByteRange
    ) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = contentRange.split(separator: "/").last,
           total != "*",
           let value = Int64(total) {
            return value
        }
        return nil
    }

    private static func responseOffset(response: HTTPURLResponse) -> Int64? {
        guard response.statusCode == 206,
              let contentRange = response.value(forHTTPHeaderField: "Content-Range") else {
            return nil
        }
        let components = contentRange.split(separator: " ", maxSplits: 1)
        guard components.count == 2,
              components[0].lowercased() == "bytes",
              let bounds = components[1].split(separator: "/", maxSplits: 1).first,
              let lower = bounds.split(separator: "-", maxSplits: 1).first else { return nil }
        return Int64(lower)
    }
}

/// URLSession retains its delegate until invalidation. Keeping that delegate
/// as a weak forwarding proxy avoids a loader/session cycle even if cache
/// construction fails before the normal player lifecycle can call cancel.
nonisolated private final class PlaybackRangeSessionDelegate: NSObject,
    URLSessionDataDelegate, @unchecked Sendable {
    weak var owner: URLSessionPlaybackRangeLoader?

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let owner else {
            completionHandler(.cancel)
            return
        }
        owner.receive(
            response: response,
            taskIdentifier: dataTask.taskIdentifier,
            completionHandler: completionHandler
        )
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.receive(data: data, taskIdentifier: dataTask.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        owner?.complete(taskIdentifier: task.taskIdentifier, error: error)
    }
}

nonisolated final class URLSessionPlaybackRangeLoader: NSObject, PlaybackRangeLoading,
    @unchecked Sendable {
    private let lock = NSLock()
    private let delegateProxy: PlaybackRangeSessionDelegate
    private var session: URLSession!
    private var active: [Int: PlaybackRangeRequest] = [:]
    private var cancelled = false
    private let authorization: MediaRequestAuthorization?

    init(configuration: URLSessionConfiguration = .ephemeral, authorization: MediaRequestAuthorization? = nil) {
        delegateProxy = PlaybackRangeSessionDelegate()
        self.authorization = authorization
        super.init()
        delegateProxy.owner = self
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: delegateProxy, delegateQueue: queue)
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func load(url: URL, range: PlaybackByteRange, priority: Float) throws -> PlaybackRangeResponse {
        var lastError: Error = PlaybackCacheError.invalidResponse
        for attempt in 0..<3 {
            let request = PlaybackRangeRequest(
                url: url,
                range: range,
                priority: priority,
                authorization: authorization
            )
            let task = session.dataTask(with: request.urlRequest)
            let identifier = task.taskIdentifier
            request.attach(task)
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                task.cancel()
                throw PlaybackCacheError.cancelled
            }
            active[identifier] = request
            lock.unlock()
            task.resume()
            do {
                let response = try request.waitForResult()
                removeActive(identifier)
                return response
            } catch PlaybackCacheError.cancelled {
                removeActive(identifier)
                throw PlaybackCacheError.cancelled
            } catch PlaybackCacheError.rangeUnsupported {
                removeActive(identifier)
                // A retry cannot make a deterministic HTTP capability
                // change, and would only delay the native fallback.
                throw PlaybackCacheError.rangeUnsupported
            } catch {
                removeActive(identifier)
                lastError = error
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
                }
            }
        }
        throw lastError
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let requests = Array(active.values)
        lock.unlock()
        requests.forEach { $0.cancel() }
        session.invalidateAndCancel()
    }

    func promote(range: PlaybackByteRange) {
        lock.lock()
        let requests = active.values.filter { $0.range == range }
        lock.unlock()
        requests.forEach { $0.promote() }
    }

    fileprivate func receive(
        response: URLResponse,
        taskIdentifier: Int,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        request(for: taskIdentifier)?.receive(
            response: response,
            completionHandler: completionHandler
        ) ?? completionHandler(.cancel)
    }

    fileprivate func receive(data: Data, taskIdentifier: Int) {
        request(for: taskIdentifier)?.receive(data: data)
    }

    fileprivate func complete(taskIdentifier: Int, error: Error?) {
        request(for: taskIdentifier)?.complete(error: error)
    }

    private func request(for identifier: Int) -> PlaybackRangeRequest? {
        lock.lock()
        defer { lock.unlock() }
        return active[identifier]
    }

    private func removeActive(_ identifier: Int) {
        lock.lock()
        active.removeValue(forKey: identifier)
        lock.unlock()
    }
}

/// One item's sparse, discardable cache file. Reads happen on FFmpeg's demux
/// queue. File/range bookkeeping is serialized, while low-priority prefetch
/// and a foreground seek may fetch independently when foreground must win.
nonisolated final class PlaybackCacheScope: @unchecked Sendable {
    let itemID: String
    let sourceURL: URL
    let fileURL: URL
    /// Bytes one cache miss fetches. FFmpeg's AVIO buffer is sized to match
    /// so a single demux read is at most a single network request.
    let requestSize: Int64

    private let byteLimit: Int64
    private let loader: PlaybackRangeLoading
    private let cancelsLoaderOnRemoval: Bool
    private let storageBudget: PlaybackCacheStorageBudget?
    private let lock = NSCondition()
    private let cancellationLock = NSLock()
    private var file: FileHandle?
    private var cached = PlaybackByteRangeSet()
    private var knownLength: Int64?
    private var networkBytes: Int64 = 0
    private var cacheHitBytes: Int64 = 0
    private var requestCount = 0
    private var networkRequestSeconds: Double = 0
    private var cancelled = false
    private var storageDisabled = false
    private var reservedBytes: Int64 = 0
    private var inFlight: [UUID: (range: PlaybackByteRange, priority: Float)] = [:]
    /// How long a foreground read waits for a promoted prefetch of its own
    /// bytes before fetching them itself. Two seconds covers a 1 MiB chunk on
    /// any link that can play the title at all; a seek past a stalled one
    /// pays at most this before it goes its own way.
    static let sharedFetchWaitSeconds: TimeInterval = 2
    /// The end of the most recent foreground demux read. FFmpeg has already
    /// translated media time into the correct container byte position here,
    /// so this is safer than estimating bytes from a VBR timeline fraction.
    private var preferredPrefetchOffset: Int64 = 0
    private var playheadPrefetchCount = 0
    private var duplicateNetworkBytes: Int64 = 0
    private var sharedFetchCount = 0
    private var timelineAnchor: PlaybackTimelineAnchor?
    /// Sparse-file granularity. Blocks are the only unit the filesystem can
    /// give back, so eviction punches the block-aligned interior of a range
    /// and leaves the ragged edges cached.
    private let blockSize: Int64
    private var evictionCount = 0
    /// Set the first time F_PUNCHHOLE fails. Without hole punching the file
    /// can only grow, so the window is abandoned and the scope falls back to
    /// a fixed cap plus unamplified reads.
    private var holePunchingUnavailable = false

    init(
        itemID: String,
        sourceURL: URL,
        expectedLength: Int64?,
        directory: URL,
        byteLimit: Int64 = 512 * 1_024 * 1_024,
        requestSize: Int64 = 8 * 1_024 * 1_024,
        loader: PlaybackRangeLoading? = nil,
        storageBudget: PlaybackCacheStorageBudget? = nil,
        cancelsLoaderOnRemoval: Bool = true,
        authorization: MediaRequestAuthorization? = nil
    ) throws {
        self.itemID = itemID
        self.sourceURL = sourceURL
        self.knownLength = expectedLength.flatMap { $0 > 0 ? $0 : nil }
        self.byteLimit = max(byteLimit, 0)
        self.requestSize = max(requestSize, 1)
        // A caller supplying its own loader (tests, or an HLS resource
        // sharing its parent's) keeps it exactly as before; only the
        // ordinary default constructs one, and that one needs the
        // credential.
        self.loader = loader ?? URLSessionPlaybackRangeLoader(authorization: authorization)
        self.cancelsLoaderOnRemoval = cancelsLoaderOnRemoval
        self.storageBudget = storageBudget
        fileURL = directory.appendingPathComponent("ranges.cache", isDirectory: false)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil),
              let file = try? FileHandle(forUpdating: fileURL) else {
            throw PlaybackCacheError.storageUnavailable
        }
        self.file = file
        var fileSystem = statfs()
        blockSize = fstatfs(file.fileDescriptor, &fileSystem) == 0 && fileSystem.f_bsize > 0
            ? Int64(fileSystem.f_bsize)
            : 4_096
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    deinit {
        file?.closeFile()
        storageBudget?.release(reservedBytes)
    }

    var contentLength: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return knownLength
    }

    var prefetchByteCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return min(knownLength ?? byteLimit, byteLimit)
    }

    var metrics: PlaybackCacheMetrics {
        lock.lock()
        defer { lock.unlock() }
        return PlaybackCacheMetrics(
            cachedBytes: cached.byteCount,
            networkBytes: networkBytes,
            cacheHitBytes: cacheHitBytes,
            requestCount: requestCount,
            networkRequestSeconds: networkRequestSeconds,
            evictionCount: evictionCount,
            resourceCount: 1,
            capacityBytes: byteLimit,
            contiguousCachedBytes: cached.contiguousUpperBound,
            contentLength: knownLength,
            cachedByteRanges: cached.ranges,
            playheadPrefetchCount: playheadPrefetchCount,
            timelineAnchor: timelineAnchor,
            isWindowed: isWindowedLocked,
            cachedBytesAheadOfPlayhead: max(
                cached.contiguousUpperBound(from: preferredPrefetchOffset) - preferredPrefetchOffset, 0
            ),
            duplicateNetworkBytes: duplicateNetworkBytes,
            sharedFetchCount: sharedFetchCount
        )
    }

    /// Records the file position selected by FFmpeg for a concrete playback
    /// time. This is presentation metadata only; scheduling continues to use
    /// FFmpeg's observed foreground reads as its authoritative hot offset.
    func setTimelineAnchor(byteOffset: Int64, timeFraction: Double) {
        guard byteOffset >= 0, timeFraction.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        let upperBound = knownLength ?? byteLimit
        timelineAnchor = PlaybackTimelineAnchor(
            byteOffset: min(byteOffset, upperBound),
            timeFraction: min(max(timeFraction, 0), 1)
        )
    }

    /// The sparse file becomes a normal playable input only after every byte
    /// in the server-declared resource has been written. Partial files never
    /// escape this type, so a player cannot mistake a hole for media EOF.
    var completeFileURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        guard !storageDisabled,
              let knownLength,
              knownLength > 0,
              cached.contains(PlaybackByteRange(0, knownLength)),
              file != nil else { return nil }
        try? file?.synchronize()
        return fileURL
    }

    func read(offset: Int64, length: Int, priority: Float = URLSessionTask.highPriority) throws -> Data {
        try read(offset: offset, length: length, priority: priority, readAhead: true)
    }

    /// Disc metadata has its own aggregate byte budget. Do not amplify a
    /// small descriptor read into the streaming cache's megabyte read-ahead.
    func readMetadata(offset: Int64, length: Int) throws -> Data {
        try read(offset: offset, length: length, priority: URLSessionTask.highPriority, readAhead: false)
    }

    private func read(offset: Int64, length: Int, priority: Float, readAhead: Bool) throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        guard Int64(length) <= Int64.max - offset else { throw PlaybackCacheError.invalidResponse }
        try checkCancellation()
        lock.lock()
        if file == nil, !storageDisabled {
            file = try? FileHandle(forUpdating: fileURL)
            if file == nil {
                disableStorageLocked()
            }
        }

        let requestedEnd = min(
            offset + Int64(length),
            knownLength ?? Int64.max
        )
        let requested = PlaybackByteRange(offset, requestedEnd)
        guard requested.count > 0 else {
            lock.unlock()
            return Data()
        }
        if priority >= URLSessionTask.defaultPriority {
            // Cached hits count too: after a backwards seek the correct hot
            // window may already be on disk, and prefetch should continue at
            // the end of that island rather than stay near the old playhead.
            preferredPrefetchOffset = requested.upperBound
        }
        if cached.contains(requested), let file {
            do {
                try file.seek(toOffset: UInt64(requested.lowerBound))
                let data = try file.read(upToCount: Int(requested.count)) ?? Data()
                if data.count == Int(requested.count) {
                    cacheHitBytes += requested.count
                    lock.unlock()
                    return data
                }
            } catch {
                // A cache file is an optimization. Storage pressure or a
                // purged file must fall through to the network, never turn
                // a healthy stream into EOF.
            }
            disableStorageLocked()
        }

        // Low-priority prefetch follows an overlapping foreground miss
        // instead of downloading the same chunk twice. A foreground seek
        // never waits behind low-priority prefetch; it starts its own request.
        if inFlight.values.contains(where: {
            $0.range.contains(requested) && $0.priority >= priority
        }) {
            _ = lock.wait(until: Date().addingTimeInterval(15))
            lock.unlock()
            return try read(offset: offset, length: length, priority: priority, readAhead: readAhead)
        }
        // Playback caught up with a prefetch of these very bytes. Starting a
        // second request used to move 2 MiB to store 1; instead promote the
        // one in flight to foreground priority and give it a bounded moment
        // to land. Past the bound the read falls through to its own request,
        // so a seek onto a slow prefetch never waits behind it.
        if priority > URLSessionTask.lowPriority,
           let pending = inFlight.values.first(where: { $0.range.contains(requested) }) {
            loader.promote(range: pending.range)
            let deadline = Date().addingTimeInterval(Self.sharedFetchWaitSeconds)
            // The condition is broadcast for every finished fetch, so keep
            // waiting until these bytes are on disk, the promoted fetch has
            // gone away (failed or cancelled), or the bound has passed.
            while !cached.contains(requested),
                  inFlight.values.contains(where: { $0.range == pending.range }),
                  lock.wait(until: deadline) {}
            if cached.contains(requested) {
                sharedFetchCount += 1
                lock.unlock()
                return try read(offset: offset, length: length, priority: priority, readAhead: readAhead)
            }
            // A scope cancelled during the wait must not start one more request.
            do {
                try checkCancellation()
            } catch {
                lock.unlock()
                throw error
            }
        }

        // Make room before deciding how much to ask for. A read whose bytes
        // cannot be kept must fetch only what the caller asked for: pulling a
        // whole request to satisfy one AVIO buffer and discarding the rest
        // multiplies both bandwidth and round trips by the ratio between them,
        // which is what turned a full cache into permanent rebuffering.
        makeRoomLocked(for: readAhead ? requestSize : requested.count)
        let readAheadEnd = readAhead && storableCapacityLocked() > 0
            ? max(requested.upperBound, requested.lowerBound + min(requestSize, Int64.max - requested.lowerBound))
            : requested.upperBound
        let fetchEnd = min(readAheadEnd, knownLength ?? Int64.max)
        let fetchRange = PlaybackByteRange(requested.lowerBound, fetchEnd)
        let fetchID = UUID()
        inFlight[fetchID] = (fetchRange, priority)
        requestCount += 1
        lock.unlock()
        let requestStarted = ProcessInfo.processInfo.systemUptime
        let response: PlaybackRangeResponse
        do {
            response = try loader.load(url: sourceURL, range: fetchRange, priority: priority)
            try checkCancellation()
        } catch {
            finishFetch(fetchID)
            throw error
        }

        lock.lock()
        do {
            try checkCancellation()
        } catch {
            inFlight.removeValue(forKey: fetchID)
            lock.broadcast()
            lock.unlock()
            throw error
        }
        inFlight.removeValue(forKey: fetchID)
        lock.broadcast()
        defer { lock.unlock() }
        networkRequestSeconds += max(ProcessInfo.processInfo.systemUptime - requestStarted, 0)
        if let total = response.totalLength, total > 0 { knownLength = total }
        networkBytes += response.transferredBytes

        makeRoomLocked(for: Int64(response.data.count))
        let remainingCapacity = storableCapacityLocked()
        let desiredCount = min(Int64(response.data.count), remainingCapacity)
        let storableCount = storageBudget?.reserve(upTo: desiredCount) ?? desiredCount
        if storableCount > 0, let file {
            let storable = response.data.prefix(Int(storableCount))
            do {
                try file.seek(toOffset: UInt64(response.offset))
                try file.write(contentsOf: storable)
                let added = cached.insert(PlaybackByteRange(response.offset, response.offset + storableCount))
                reservedBytes += added
                duplicateNetworkBytes += storableCount - added
                storageBudget?.release(storableCount - added)
            } catch {
                storageBudget?.release(storableCount)
                disableStorageLocked()
            }
        } else if storableCount > 0 {
            storageBudget?.release(storableCount)
        }
        let relativeOffset = max(requested.lowerBound - response.offset, 0)
        guard relativeOffset < response.data.count else { return Data() }
        let available = min(Int64(response.data.count) - relativeOffset, requested.count)
        return response.data.subdata(in: Int(relativeOffset)..<Int(relativeOffset + available))
    }

    func prefetch(byteCount: Int64) async {
        guard byteCount > 0 else { return }
        await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var offset: Int64 = 0
            while offset < byteCount, !Task.isCancelled {
                let count = Int(min(self.requestSize, byteCount - offset))
                guard let data = try? self.read(
                    offset: offset,
                    length: count,
                    priority: URLSessionTask.lowPriority
                ), !data.isEmpty else { return }
                offset += Int64(data.count)
            }
        }.value
    }

    /// Fetches at most one bounded chunk after the uninterrupted cached
    /// prefix. The controller deliberately schedules one chunk at a time so
    /// foreground playback can pause or throttle proactive traffic between
    /// requests instead of being trapped behind a whole-title download.
    func prefetchNextChunk() async -> PlaybackPrefetchOutcome {
        await Task.detached(priority: .utility) { [weak self] in
            guard let self, !Task.isCancelled else { return .cancelled }
            let (offset, count) = self.nextPrefetchWindow()
            guard count > 0 else { return .exhausted }
            guard !Task.isCancelled else { return .cancelled }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let data = try self.read(
                    offset: offset,
                    length: count,
                    priority: URLSessionTask.lowPriority
                )
                guard !data.isEmpty else { return .exhausted }
                return .fetched(bytes: data.count, seconds: max(ProcessInfo.processInfo.systemUptime - started, 0))
            } catch PlaybackCacheError.cancelled {
                return .cancelled
            } catch {
                return .failed
            }
        }.value
    }

    private func nextPrefetchWindow() -> (offset: Int64, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !storageDisabled else { return (0, 0) }

        if isWindowedLocked {
            // Read-ahead only, and only as far as the window reaches. Closing
            // a hole behind the window would be evicted by the next request,
            // and clamping the search to the first `byteLimit` bytes — as the
            // whole-file scheduler below does — would stop buffering entirely
            // once the playhead passed the cap.
            let window = hotWindowLocked
            let upperBound = min(window.upperBound, knownLength ?? window.upperBound)
            let start = min(max(preferredPrefetchOffset, 0), upperBound)
            guard let range = cached.firstUncachedRange(
                startingAt: start,
                endingBefore: upperBound,
                maximumCount: requestSize
            ) else { return (0, 0) }
            playheadPrefetchCount += 1
            return (range.lowerBound, Int(range.count))
        }

        let upperBound = min(knownLength ?? byteLimit, byteLimit)
        guard cached.byteCount < byteLimit, upperBound > 0 else {
            return (0, 0)
        }

        let prefixEnd = cached.contiguousUpperBound
        let preferred = min(max(preferredPrefetchOffset, 0), upperBound)
        if preferred > prefixEnd,
           let range = cached.firstUncachedRange(
               startingAt: preferred,
               endingBefore: upperBound,
               maximumCount: requestSize
           ) {
            playheadPrefetchCount += 1
            return (range.lowerBound, Int(range.count))
        }

        // Once the hot playhead-to-EOF window is complete, wrap around and
        // close the oldest remaining hole. This still allows a whole cached
        // file to emerge, just without making a new seek wait behind it.
        guard let range = cached.firstUncachedRange(
            startingAt: 0,
            endingBefore: upperBound,
            maximumCount: requestSize
        ) else { return (0, 0) }
        return (range.lowerBound, Int(range.count))
    }

    // MARK: - Sliding window

    /// A cache large enough for the whole title keeps its original behaviour:
    /// nothing is evicted and proactive fill converges on a complete file.
    /// A title larger than the cap cannot do that — filling to the cap and
    /// stopping leaves the rest of the movie uncached, and every later read
    /// then pays a network round trip. Those titles get a window that travels
    /// with the playhead instead.
    private var isWindowedLocked: Bool {
        guard byteLimit > 0, !holePunchingUnavailable else { return false }
        guard let knownLength else { return true }
        return knownLength > byteLimit
    }

    /// Bytes kept behind the playhead so ordinary backwards scrubbing stays
    /// local. Everything else buffers ahead, which is what actually protects
    /// playback from network jitter.
    private var retainBehindLocked: Int64 {
        min(byteLimit / 8, 256 * 1_024 * 1_024)
    }

    /// A whole cap's worth of file, positioned around the playhead. Only the
    /// bytes that actually exist behind the playhead count against the
    /// reserve: near the start of a title the lower half of the window would
    /// otherwise hang off the front of the file, and that capacity simply
    /// went unused — a viewer who paused a minute in buffered up to 256 MiB
    /// less than the cache was allowed to hold. Read-ahead takes whatever the
    /// reserve does not need, so the window stays [0, cap] until the playhead
    /// has passed the reserve distance and only then begins to slide.
    private var hotWindowLocked: PlaybackByteRange {
        let playhead = max(preferredPrefetchOffset, 0)
        let behind = min(retainBehindLocked, playhead)
        // At least one request: the window has to contain the fetch being
        // issued right now, or eviction would drop the bytes it just paid for.
        let ahead = max(byteLimit - behind, requestSize)
        return PlaybackByteRange(playhead - behind, playhead + ahead)
    }

    /// Disk the sparse file actually occupies. The logical range set is not
    /// enough on its own: punching a hole is the only way to hand blocks
    /// back, so if the filesystem refuses, real allocation is what has to
    /// hold the cap. A few blocks of slack absorb the difference between
    /// byte-exact bookkeeping and block-granular allocation.
    private func allocatedBytesLocked() -> Int64 {
        guard let file else { return 0 }
        var status = stat()
        guard fstat(file.fileDescriptor, &status) == 0 else { return 0 }
        return max(Int64(status.st_blocks) * 512 - 4 * blockSize, 0)
    }

    /// Bytes that may still be written before the cap binds, measured against
    /// whichever of the two accountings is currently worse.
    private func storableCapacityLocked() -> Int64 {
        guard !storageDisabled else { return 0 }
        return max(byteLimit - max(cached.byteCount, allocatedBytesLocked()), 0)
    }

    /// Deallocates the block-aligned interior of a range and returns exactly
    /// what was freed. Partial blocks at either edge still hold bytes the
    /// cache is keeping, so they stay in the range set.
    private func punchLocked(_ range: PlaybackByteRange) -> PlaybackByteRange? {
        guard let file, blockSize > 0, !holePunchingUnavailable else { return nil }
        let lower = ((range.lowerBound + blockSize - 1) / blockSize) * blockSize
        let upper = (range.upperBound / blockSize) * blockSize
        guard upper > lower else { return nil }
        var request = fpunchhole_t(
            fp_flags: 0,
            reserved: 0,
            fp_offset: off_t(lower),
            fp_length: off_t(upper - lower)
        )
        let punched = withUnsafeMutablePointer(to: &request) {
            fcntl(file.fileDescriptor, F_PUNCHHOLE, UnsafeMutableRawPointer($0)) == 0
        }
        guard punched else {
            // Without reclaimable space the window cannot hold the cap.
            // Fall back to a fixed cap; reads stay unamplified because they
            // stop asking for bytes they are not allowed to keep.
            holePunchingUnavailable = true
            return nil
        }
        return PlaybackByteRange(lower, upper)
    }

    /// Frees room for `byteCount` by dropping cached islands furthest from
    /// the playhead first, and only ever from outside the retained window.
    /// `preferredPrefetchOffset` follows every foreground read, so a
    /// backwards seek re-centres the window on its next demux read and the
    /// bytes that are now far *ahead* become the eviction candidates.
    private func makeRoomLocked(for byteCount: Int64) {
        guard byteCount > 0, isWindowedLocked else { return }
        var shortfall = byteCount - storableCapacityLocked()
        guard shortfall > 0 else { return }

        let window = hotWindowLocked
        let playhead = max(preferredPrefetchOffset, 0)
        var candidates: [PlaybackByteRange] = []
        for range in cached.ranges {
            if range.lowerBound < window.lowerBound {
                candidates.append(
                    PlaybackByteRange(range.lowerBound, min(range.upperBound, window.lowerBound))
                )
            }
            if range.upperBound > window.upperBound {
                candidates.append(
                    PlaybackByteRange(max(range.lowerBound, window.upperBound), range.upperBound)
                )
            }
        }
        candidates.sort {
            Self.distance(of: $0, from: playhead) > Self.distance(of: $1, from: playhead)
        }

        for candidate in candidates {
            guard shortfall > 0 else { break }
            // Give back only what is needed, taken from the end of the island
            // furthest from the playhead. Dropping a whole island to make room
            // for one request would throw away read-ahead that is still worth
            // more than the bytes replacing it.
            let trimmed = candidate.lowerBound >= playhead
                ? PlaybackByteRange(max(candidate.upperBound - shortfall, candidate.lowerBound), candidate.upperBound)
                : PlaybackByteRange(candidate.lowerBound, min(candidate.lowerBound + shortfall, candidate.upperBound))
            guard let punched = punchLocked(trimmed) else {
                if holePunchingUnavailable { return }
                continue
            }
            let removed = cached.remove(punched)
            guard removed > 0 else { continue }
            reservedBytes = max(reservedBytes - removed, 0)
            storageBudget?.release(removed)
            shortfall -= removed
            evictionCount += 1
        }
    }

    private static func distance(of range: PlaybackByteRange, from playhead: Int64) -> Int64 {
        if range.upperBound <= playhead { return playhead - range.upperBound }
        if range.lowerBound >= playhead { return range.lowerBound - playhead }
        return 0
    }

    func cancelAndRemove() {
        cancellationLock.lock()
        guard !cancelled else {
            cancellationLock.unlock()
            return
        }
        cancelled = true
        cancellationLock.unlock()
        if cancelsLoaderOnRemoval {
            loader.cancelAll()
        }
        lock.lock()
        lock.broadcast()
        let releasedBytes = reservedBytes
        reservedBytes = 0
        lock.unlock()
        storageBudget?.release(releasedBytes)
        // A range request may still be unwinding on the demux queue. File
        // closure and deletion wait there, never on the main actor that is
        // animating player dismissal or an episode handoff.
        DispatchQueue.global(qos: .utility).async { [self] in
            lock.lock()
            file?.closeFile()
            file = nil
            let directory = fileURL.deletingLastPathComponent()
            lock.unlock()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// HLS retains range metadata for backwards seeks while closing inactive
    /// segment handles, keeping long movies far below tvOS descriptor limits.
    func suspendStorage() {
        lock.lock()
        file?.closeFile()
        file = nil
        lock.unlock()
    }

    private func checkCancellation() throws {
        cancellationLock.lock()
        let isCancelled = cancelled
        cancellationLock.unlock()
        if isCancelled { throw PlaybackCacheError.cancelled }
    }

    private func finishFetch(_ identifier: UUID) {
        lock.lock()
        inFlight.removeValue(forKey: identifier)
        lock.broadcast()
        lock.unlock()
    }

    private func disableStorageLocked() {
        storageDisabled = true
        cached = PlaybackByteRangeSet()
        let releasedBytes = reservedBytes
        reservedBytes = 0
        storageBudget?.release(releasedBytes)
    }

}

/// One checked-out HLS media resource. FFmpeg may keep several segments open
/// at once; a lease prevents the bounded LRU from evicting an AVIO context
/// that is still reading. Playlists never enter this cache because Jellyfin
/// can update them while a transcode is still being produced.
nonisolated final class HLSPlaybackCacheLease: @unchecked Sendable {
    let scope: PlaybackCacheScope

    private weak var owner: HLSPlaybackCacheScope?
    private let key: String
    private let generation: UUID
    private let lock = NSLock()
    private var isClosed = false

    fileprivate init(
        scope: PlaybackCacheScope,
        owner: HLSPlaybackCacheScope,
        key: String,
        generation: UUID
    ) {
        self.scope = scope
        self.owner = owner
        self.key = key
        self.generation = generation
    }

    deinit { close() }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let owner = self.owner
        lock.unlock()
        owner?.release(key: key, generation: generation)
    }
}

/// A VOD HLS cache made of small per-resource sparse files. A shared budget
/// keeps aggregate storage at 512 MiB, each resource is capped at 32 MiB, and
/// inactive file handles are closed so a long movie cannot exhaust tvOS file
/// descriptors. Closed entries are evicted LRU; active AVIO leases are never
/// removed underneath FFmpeg.
nonisolated final class HLSPlaybackCacheScope: @unchecked Sendable {
    let itemID: String
    let sourceURL: URL

    private struct Entry {
        let generation: UUID
        let scope: PlaybackCacheScope
        var activeLeases: Int
        var lastAccess: UInt64
    }

    private let directory: URL
    private let byteLimit: Int64
    private let resourceByteLimit: Int64
    private let requestSize: Int64
    private let maxResources: Int
    private let storageBudget: PlaybackCacheStorageBudget
    private let resourceLoader: PlaybackRangeLoading
    private let playlistLoader: PlaybackRangeLoading
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var accessCounter: UInt64 = 0
    private var retiredMetrics = PlaybackCacheMetrics.zero
    private var evictionCount = 0
    private var cancelled = false

    init(
        itemID: String,
        sourceURL: URL,
        directory: URL,
        byteLimit: Int64 = 512 * 1_024 * 1_024,
        maxResources: Int = 256,
        requestSize: Int64 = 8 * 1_024 * 1_024,
        resourceLoader: PlaybackRangeLoading? = nil,
        playlistLoader: PlaybackRangeLoading? = nil,
        authorization: MediaRequestAuthorization? = nil
    ) throws {
        self.itemID = itemID
        self.sourceURL = sourceURL
        self.directory = directory
        self.byteLimit = max(byteLimit, 0)
        self.maxResources = max(maxResources, 1)
        resourceByteLimit = max(min(byteLimit, 32 * 1_024 * 1_024), 1)
        self.requestSize = max(min(requestSize, resourceByteLimit), 1)
        storageBudget = PlaybackCacheStorageBudget(byteLimit: byteLimit)
        // Test doubles keep whatever loader they were given; the ordinary
        // defaults each get their own session, both carrying the credential
        // segments and the manifest itself need.
        self.resourceLoader = resourceLoader ?? URLSessionPlaybackRangeLoader(authorization: authorization)
        self.playlistLoader = playlistLoader ?? URLSessionPlaybackRangeLoader(authorization: authorization)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var prefetchByteCount: Int64 {
        byteLimit
    }

    var metrics: PlaybackCacheMetrics {
        lock.lock()
        let scopes = entries.values.map(\.scope)
        let retired = retiredMetrics
        let evictions = evictionCount
        lock.unlock()
        return scopes
            .reduce(retired) { $0.adding($1.metrics) }
            .reporting(
                evictionCount: evictions,
                resourceCount: scopes.count,
                capacityBytes: byteLimit
            )
    }

    var cachedResourceURLs: Set<URL> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.keys.compactMap(URL.init(string:)))
    }

    /// Returns nil for mutable playlists, unsupported URL schemes, a stopped
    /// session, or the rare case where every bounded slot is actively leased.
    /// The demuxer falls back to avio_open2 in all of those cases.
    func leaseResource(at url: URL) throws -> HLSPlaybackCacheLease? {
        guard Self.shouldCache(url: url) else { return nil }
        let key = url.absoluteString
        var retiredScopes: [PlaybackCacheScope] = []

        lock.lock()
        guard !cancelled else {
            lock.unlock()
            throw PlaybackCacheError.cancelled
        }
        accessCounter &+= 1
        if var entry = entries[key] {
            entry.activeLeases += 1
            entry.lastAccess = accessCounter
            entries[key] = entry
            let lease = HLSPlaybackCacheLease(
                scope: entry.scope,
                owner: self,
                key: key,
                generation: entry.generation
            )
            lock.unlock()
            return lease
        }

        var anticipatedAvailable = storageBudget.availableBytes
        while entries.count >= maxResources || anticipatedAvailable < requestSize {
            guard let candidate = entries
                .filter({ $0.value.activeLeases == 0 })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess }),
                  let removed = entries.removeValue(forKey: candidate.key) else {
                break
            }
            let metrics = removed.scope.metrics
            retiredMetrics = retiredMetrics.adding(metrics, includeCachedBytes: false)
            evictionCount += 1
            anticipatedAvailable += metrics.cachedBytes
            retiredScopes.append(removed.scope)
        }
        if entries.count >= maxResources {
            lock.unlock()
            retiredScopes.forEach { $0.cancelAndRemove() }
            return nil
        }

        let generation = UUID()
        let resourceDirectory = directory.appendingPathComponent(generation.uuidString, isDirectory: true)
        let scope: PlaybackCacheScope
        do {
            scope = try PlaybackCacheScope(
                itemID: itemID,
                sourceURL: url,
                expectedLength: nil,
                directory: resourceDirectory,
                byteLimit: resourceByteLimit,
                requestSize: requestSize,
                loader: resourceLoader,
                storageBudget: storageBudget,
                cancelsLoaderOnRemoval: false
            )
        } catch {
            lock.unlock()
            retiredScopes.forEach { $0.cancelAndRemove() }
            throw error
        }
        entries[key] = Entry(
            generation: generation,
            scope: scope,
            activeLeases: 1,
            lastAccess: accessCounter
        )
        let lease = HLSPlaybackCacheLease(
            scope: scope,
            owner: self,
            key: key,
            generation: generation
        )
        lock.unlock()
        retiredScopes.forEach { $0.cancelAndRemove() }
        return lease
    }

    /// Warm a transcode's selected media resources. The playlist is read
    /// without persistence so a growing Jellyfin transcode can never be
    /// frozen at an old manifest. Current playback still fills every segment
    /// FFmpeg consumes, while an 8 MiB staged warmup reaches the first frame.
    func prefetch(byteCount: Int64) async {
        guard byteCount > 0 else { return }
        await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let resources = try self.firstMediaResources()
                var remaining = byteCount
                for url in resources where remaining > 0 && !Task.isCancelled {
                    guard let lease = try self.leaseResource(at: url) else { continue }
                    let before = lease.scope.metrics.cachedBytes
                    await lease.scope.prefetch(byteCount: min(self.resourceByteLimit, remaining))
                    let added = max(lease.scope.metrics.cachedBytes - before, 0)
                    lease.close()
                    remaining -= max(added, 1)
                }
            } catch {
                // Prefetch is opportunistic. FFmpeg's native/cached foreground
                // opens remain authoritative if manifest warmup is unavailable.
            }
        }.value
    }

    func cancelAndRemove() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let scopes = entries.values.map(\.scope)
        entries.removeAll(keepingCapacity: false)
        lock.unlock()
        playlistLoader.cancelAll()
        resourceLoader.cancelAll()
        scopes.forEach { $0.cancelAndRemove() }
        DispatchQueue.global(qos: .utility).async { [directory] in
            try? FileManager.default.removeItem(at: directory)
        }
    }

    fileprivate func release(key: String, generation: UUID) {
        lock.lock()
        guard var entry = entries[key], entry.generation == generation else {
            lock.unlock()
            return
        }
        entry.activeLeases = max(entry.activeLeases - 1, 0)
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        entries[key] = entry
        if entry.activeLeases == 0 {
            entry.scope.suspendStorage()
        }
        lock.unlock()
    }

    static func shouldCache(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return url.pathExtension.lowercased() != "m3u8"
    }

    /// Resolve one master indirection plus its media playlist. Jellyfin's
    /// transcode profile normally exposes one video variant. Attribute URIs
    /// (for example alternate audio) are excluded from variant selection.
    private func firstMediaResources() throws -> [URL] {
        var playlistURL = sourceURL
        for _ in 0..<2 {
            let response = try playlistLoader.load(
                url: playlistURL,
                range: PlaybackByteRange(0, 1_024 * 1_024),
                priority: URLSessionTask.lowPriority
            )
            let references = Self.playlistReferences(data: response.data, relativeTo: playlistURL)
            if let childPlaylist = Self.variantPlaylistURLs(
                data: response.data,
                relativeTo: playlistURL
            ).last {
                playlistURL = childPlaylist
                continue
            }
            return references.filter(Self.shouldCache)
        }
        return []
    }

    static func playlistReferences(data: Data, relativeTo baseURL: URL) -> [URL] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var references: [URL] = []
        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                guard let uriRange = line.range(of: "URI=\"") else { continue }
                let remainder = line[uriRange.upperBound...]
                guard let closingQuote = remainder.firstIndex(of: "\"") else { continue }
                let value = String(remainder[..<closingQuote])
                if let url = URL(string: value, relativeTo: baseURL)?.absoluteURL {
                    references.append(url)
                }
            } else if !line.isEmpty,
                      let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                references.append(url)
            }
        }
        return references
    }

    static func variantPlaylistURLs(data: Data, relativeTo baseURL: URL) -> [URL] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
            .filter { $0.pathExtension.lowercased() == "m3u8" }
    }
}

/// Uniform player-facing ownership for either a single direct-file cache or
/// an HLS resource cache. Keeping the mode inside this object lets next-item
/// promotion and lifecycle cleanup use the same invariant for every method.
nonisolated final class PlaybackCacheSession: @unchecked Sendable {
    enum Storage {
        case direct(PlaybackCacheScope)
        case hls(HLSPlaybackCacheScope)
    }

    let itemID: String
    let sourceURL: URL
    let storage: Storage

    init(itemID: String, sourceURL: URL, storage: Storage) {
        self.itemID = itemID
        self.sourceURL = sourceURL
        self.storage = storage
    }

    var directScope: PlaybackCacheScope? {
        guard case .direct(let scope) = storage else { return nil }
        return scope
    }

    var hlsScope: HLSPlaybackCacheScope? {
        guard case .hls(let scope) = storage else { return nil }
        return scope
    }

    var metrics: PlaybackCacheMetrics {
        switch storage {
        case .direct(let scope): scope.metrics
        case .hls(let scope): scope.metrics
        }
    }

    var completeFileURL: URL? {
        directScope?.completeFileURL
    }

    var prefetchByteCount: Int64 {
        switch storage {
        case .direct(let scope): scope.prefetchByteCount
        case .hls(let scope): scope.prefetchByteCount
        }
    }

    func prefetch(byteCount: Int64) async {
        switch storage {
        case .direct(let scope): await scope.prefetch(byteCount: byteCount)
        case .hls(let scope): await scope.prefetch(byteCount: byteCount)
        }
    }

    func prefetchNextChunk() async -> PlaybackPrefetchOutcome {
        switch storage {
        case .direct(let scope):
            return await scope.prefetchNextChunk()
        case .hls:
            // HLS progress is segment-shaped rather than a contiguous byte
            // timeline. Its bounded warmup remains explicit in prefetch(_:).
            return .exhausted
        }
    }

    func cancelAndRemove() {
        switch storage {
        case .direct(let scope): scope.cancelAndRemove()
        case .hls(let scope): scope.cancelAndRemove()
        }
    }
}

/// Main-actor ownership of the only two cache scopes Lagoon permits: the
/// active item and its staged successor.
@MainActor
final class PlaybackCacheCoordinator {
    private let rootDirectory: URL
    private let byteLimit: Int64
    private let isEnabled: Bool
    private let allowsTranscodeCaching: Bool
    private(set) var current: PlaybackCacheSession?
    private(set) var next: PlaybackCacheSession?

    init(
        rootDirectory: URL? = nil,
        byteLimit: Int64? = nil,
        isEnabled: Bool,
        allowsTranscodeCaching: Bool = PlaybackBufferPolicy.customIOEnabled(for: .transcode)
    ) {
        let caches = rootDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.rootDirectory = caches
            .appendingPathComponent("Lagoon", isDirectory: true)
            .appendingPathComponent("Playback", isDirectory: true)
        let volumeAttributes = try? FileManager.default.attributesOfFileSystem(
            forPath: caches.path
        )
        let available = (volumeAttributes?[.systemFreeSize] as? NSNumber)?.int64Value
        self.byteLimit = byteLimit
            ?? Self.debugByteLimitOverride()
            ?? Self.recommendedByteLimit(availableBytes: available)
        self.isEnabled = isEnabled
        self.allowsTranscodeCaching = allowsTranscodeCaching
        removeStaleScopes()
    }

    func activate(
        itemID: String,
        url: URL,
        method: PlayMethod,
        expectedLength: Int64?,
        authorization: MediaRequestAuthorization? = nil
    ) -> PlaybackCacheSession? {
        if let next, next.itemID == itemID, next.sourceURL == url {
            current?.cancelAndRemove()
            current = next
            self.next = nil
            return next
        }
        current?.cancelAndRemove()
        current = makeScope(itemID: itemID, url: url, method: method, expectedLength: expectedLength, authorization: authorization)
        return current
    }

    func stageNext(
        itemID: String,
        url: URL,
        method: PlayMethod,
        expectedLength: Int64?,
        authorization: MediaRequestAuthorization? = nil
    ) -> PlaybackCacheSession? {
        if next?.itemID == itemID, next?.sourceURL == url { return next }
        next?.cancelAndRemove()
        next = makeScope(itemID: itemID, url: url, method: method, expectedLength: expectedLength, authorization: authorization)
        return next
    }

    func discardNext(itemID: String? = nil) {
        guard itemID == nil || next?.itemID == itemID else { return }
        next?.cancelAndRemove()
        next = nil
    }

    func discardCurrent(preservingNext: Bool) {
        current?.cancelAndRemove()
        current = nil
        if !preservingNext {
            discardNext()
        }
    }

    func discardAll() {
        discardCurrent(preservingNext: false)
    }

    private func makeScope(
        itemID: String,
        url: URL,
        method: PlayMethod,
        expectedLength: Int64?,
        authorization: MediaRequestAuthorization?
    ) -> PlaybackCacheSession? {
        guard isEnabled, byteLimit > 0 else { return nil }
        let directory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        switch method {
        case .directPlay, .directStream:
            let declaredLength = expectedLength.flatMap { $0 > 0 ? $0 : nil }
            let resourceLimit = min(declaredLength ?? byteLimit, byteLimit)
            guard let scope = try? PlaybackCacheScope(
                itemID: itemID,
                sourceURL: url,
                expectedLength: expectedLength,
                directory: directory,
                byteLimit: resourceLimit,
                requestSize: 1 * 1_024 * 1_024,
                authorization: authorization
            ) else { return nil }
            return PlaybackCacheSession(
                itemID: itemID,
                sourceURL: url,
                storage: .direct(scope)
            )
        case .transcode:
            guard allowsTranscodeCaching else { return nil }
            guard let scope = try? HLSPlaybackCacheScope(
                itemID: itemID,
                sourceURL: url,
                directory: directory,
                byteLimit: byteLimit,
                authorization: authorization
            ) else { return nil }
            return PlaybackCacheSession(
                itemID: itemID,
                sourceURL: url,
                storage: .hls(scope)
            )
        }
    }

    /// Use cache storage only after preserving a fixed 256 MiB safety reserve.
    /// Half of the remaining volume is available to the current title, which
    /// lets ordinary episodes and movies finish buffering when space permits
    /// without letting one disposable file consume the device.
    nonisolated static func recommendedByteLimit(availableBytes: Int64?) -> Int64 {
        let mebibyte: Int64 = 1_024 * 1_024
        let minimum = 64 * mebibyte
        let safetyReserve = 256 * mebibyte
        let unknownVolumeFallback = 2 * 1_024 * mebibyte
        guard let availableBytes else { return unknownVolumeFallback }
        guard availableBytes >= safetyReserve + minimum else { return 0 }
        return max(minimum, (availableBytes - safetyReserve) / 2)
    }

    /// A device only reaches the windowed path after buffering gigabytes, so
    /// `debug.playbackCacheCapMB` forces a small cap and makes the sliding
    /// window observable within a minute of ordinary playback.
    private static func debugByteLimitOverride() -> Int64? {
        #if DEBUG
        let megabytes = UserDefaults.standard.integer(forKey: "debug.playbackCacheCapMB")
        return megabytes > 0 ? Int64(megabytes) * 1_024 * 1_024 : nil
        #else
        return nil
        #endif
    }

    private func removeStaleScopes() {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let children = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        for child in children ?? [] {
            let values = try? child.resourceValues(forKeys: keys)
            guard values?.isDirectory == true,
                  let modified = values?.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
}
