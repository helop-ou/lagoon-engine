import CommonCrypto
import Foundation
import Libavformat
import Libavutil

// Transport spike: libavformat is rebuilt without its
// network stack, so http/https opens can no longer resolve themselves.
// Every byte a demuxed AVFormatContext needs from the network — the top-level
// manifest/file plus every HLS child resource and key — now comes from
// URLSession, which is also where system certificate trust now lives instead
// of the tls_verify/verifyhost options FFmpeg's own TLS used to take.

nonisolated let ffmpegErrorExit: Int32 = -1_414_092_869 // AVERROR_EXIT
nonisolated let ffmpegErrorIO: Int32 = -5 // AVERROR(EIO)
nonisolated let ffmpegErrorInvalid: Int32 = -22 // AVERROR(EINVAL)

/// Errors this file's byte sources throw. `FFmpegCachedIO.read` collapses
/// any of them to `AVERROR(EIO)` — see its comment on why an error must
/// never read as EOF — so the specific case only matters to retry/close
/// bookkeeping in this file.
nonisolated enum FFmpegTransportError: Error {
    case closed
    case interrupted
    case invalidResponse
    case httpStatus(Int)
    case timeout
    case invalidOffset
    case decodingFailed
}

/// Cancellable regardless of which byte source `FFmpegNetworkTransport`
/// opened — lets `close`/`closeAll` treat both the plain and AES-wrapped
/// cases the same way.
nonisolated private protocol TransportCancellable: AnyObject {
    func cancel()
}

/// Forwards one shared URLSession's delegate callbacks to whichever
/// `URLSessionByteSource` currently owns each task. A transport hands out
/// one session to every AVIOContext it opens — the root plus every HLS
/// child — so many byte sources multiplex one delegate instance, told apart
/// by task identifier the way `PlaybackRangeSessionDelegate` tells apart
/// requests in PlaybackCache.swift.
private final class FFmpegTransportSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [Int: URLSessionByteSource] = [:]
    private let authorization: MediaRequestAuthorization?

    init(authorization: MediaRequestAuthorization?) {
        self.authorization = authorization
    }

    func register(_ source: URLSessionByteSource, for taskIdentifier: Int) {
        lock.lock()
        targets[taskIdentifier] = source
        lock.unlock()
    }

    func unregister(taskIdentifier: Int) {
        lock.lock()
        targets.removeValue(forKey: taskIdentifier)
        lock.unlock()
    }

    private func target(for taskIdentifier: Int) -> URLSessionByteSource? {
        lock.lock()
        defer { lock.unlock() }
        return targets[taskIdentifier]
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let target = target(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        target.receive(response: response, taskIdentifier: dataTask.taskIdentifier, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        target(for: dataTask.taskIdentifier)?.receive(data: data, taskIdentifier: dataTask.taskIdentifier)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let identifier = task.taskIdentifier
        target(for: identifier)?.complete(error: error, taskIdentifier: identifier)
        unregister(taskIdentifier: identifier)
    }

    /// The credential header must never follow a request across origins:
    /// this is the one point where URLSession itself would otherwise carry
    /// it there on our behalf. Starts from `newRequest`; when the
    /// authorization does not apply to its URL the header is stripped, and
    /// when it does apply the header is (re-)set and the credential query
    /// items are stripped, exactly as the first request was built.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let authorization else {
            completionHandler(newRequest)
            return
        }
        var request = newRequest
        if let url = request.url, authorization.applies(to: url) {
            authorization.apply(to: &request)
        } else {
            request.setValue(nil, forHTTPHeaderField: authorization.headerName)
        }
        completionHandler(request)
    }
}

/// Owns every AVIOContext one AVFormatContext opens through Lagoon's own
/// transport. libavformat is built without its network stack, so http and
/// https reach the server through URLSession, which is also where system
/// certificate trust lives.
nonisolated final class FFmpegNetworkTransport: @unchecked Sendable {
    private struct TrackedContext {
        let io: FFmpegCachedIO
        let lease: HLSPlaybackCacheLease?
        let cancellable: (any TransportCancellable)?
    }

    private let isInterrupted: @Sendable () -> Bool
    private let hlsCache: HLSPlaybackCacheScope?
    private let session: URLSession
    private let delegate: FFmpegTransportSessionDelegate
    private let authorization: MediaRequestAuthorization?

    private let stateLock = NSLock()
    private var tracked: [UInt: TrackedContext] = [:]

    // FFmpeg's default stderr logger prints complete HLS URLs on failures,
    // including Jellyfin's query token. Lagoon reports av_strerror results
    // and its own playback diagnostics; do not emit the native raw URL
    // messages. One-shot: av_log_set_level is process-global state.
    private static let configureLogging: Void = {
        av_log_set_level(AV_LOG_QUIET)
    }()

    init(
        isInterrupted: @escaping @Sendable () -> Bool,
        hlsCache: HLSPlaybackCacheScope? = nil,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        authorization: MediaRequestAuthorization? = nil
    ) {
        self.isInterrupted = isInterrupted
        self.hlsCache = hlsCache
        self.authorization = authorization
        let sessionDelegate = FFmpegTransportSessionDelegate(authorization: authorization)
        delegate = sessionDelegate
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Sets `context.pointee.opaque` to an unretained pointer to self and
    /// installs `io_open`/`io_close2`. libavformat copies `opaque`, `io_open`
    /// and `io_close2` into nested HLS format contexts, so installing once
    /// on the root covers every child.
    func install(on context: UnsafeMutablePointer<AVFormatContext>) {
        _ = Self.configureLogging
        context.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
        context.pointee.io_open = { context, output, url, flags, options in
            guard let opaque = context?.pointee.opaque else { return ffmpegErrorIO }
            return Unmanaged<FFmpegNetworkTransport>
                .fromOpaque(opaque)
                .takeUnretainedValue()
                .open(context: context, output: output, url: url, flags: flags, options: options)
        }
        context.pointee.io_close2 = { context, ioContext in
            guard let opaque = context?.pointee.opaque else { return ffmpegErrorIO }
            return Unmanaged<FFmpegNetworkTransport>
                .fromOpaque(opaque)
                .takeUnretainedValue()
                .close(ioContext)
        }
    }

    /// The io_open implementation (also callable directly by tests). Returns
    /// 0 and writes `output.pointee` on success, or a negative AVERROR.
    func open(
        context: UnsafeMutablePointer<AVFormatContext>?,
        output: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>?,
        url: UnsafePointer<CChar>?,
        flags: Int32,
        options: UnsafeMutablePointer<OpaquePointer?>?
    ) -> Int32 {
        _ = Self.configureLogging
        if isInterrupted() { return ffmpegErrorExit }
        guard let output, let url else { return ffmpegErrorInvalid }
        let urlString = String(cString: url)

        if urlString.hasPrefix("crypto+") {
            return openCrypto(urlString: urlString, output: output, options: options)
        }

        switch URL(string: urlString)?.scheme?.lowercased() {
        case "http", "https":
            return openHTTP(urlString: urlString, output: output, flags: flags)
        default:
            return openNative(context: context, output: output, url: url, flags: flags, options: options)
        }
    }

    /// The io_close2 implementation. Frees a context this transport opened;
    /// passes anything else to `avio_closep`.
    func close(_ context: UnsafeMutablePointer<AVIOContext>?) -> Int32 {
        guard let context else { return 0 }
        stateLock.lock()
        let entry = tracked.removeValue(forKey: UInt(bitPattern: context))
        stateLock.unlock()
        guard let entry else {
            var native: UnsafeMutablePointer<AVIOContext>? = context
            return avio_closep(&native)
        }
        entry.cancellable?.cancel()
        entry.io.close()
        entry.lease?.close()
        return 0
    }

    /// Cancels in-flight requests and frees every tracked context. The
    /// demuxer calls it from `close()` after `avformat_close_input`.
    func closeAll() {
        stateLock.lock()
        let entries = Array(tracked.values)
        tracked.removeAll(keepingCapacity: false)
        stateLock.unlock()
        for entry in entries {
            entry.cancellable?.cancel()
            entry.io.close()
            entry.lease?.close()
        }
        session.invalidateAndCancel()
    }

    // MARK: - Opening by scheme

    /// `crypto+<url>` is how hls.c asks for an AES-128-CBC segment: the key
    /// and IV travel as hex strings in `options` (`ff_data_to_hex` on the
    /// native side) rather than in the URL itself.
    private func openCrypto(
        urlString: String,
        output: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>,
        options: UnsafeMutablePointer<OpaquePointer?>?
    ) -> Int32 {
        let innerURLString = String(urlString.dropFirst("crypto+".count))
        guard let innerURL = URL(string: innerURLString),
              let keyHex = Self.dictionaryValue(options, "key"),
              let ivHex = Self.dictionaryValue(options, "iv"),
              let key = Self.decodeHex(keyHex), key.count == 16,
              let iv = Self.decodeHex(ivHex), iv.count == 16 else {
            return ffmpegErrorInvalid
        }
        let inner = URLSessionByteSource(url: innerURL, session: session, isInterrupted: isInterrupted, authorization: authorization)
        let decrypted = AES128CBCByteSource(inner: inner, key: key, iv: iv)
        do {
            let io = try FFmpegCachedIO(source: decrypted, bufferSize: 64 * 1_024)
            guard let ioContext = io.context else {
                decrypted.cancel()
                return ffmpegErrorIO
            }
            track(ioContext: ioContext, io: io, lease: nil, cancellable: decrypted)
            output.pointee = ioContext
            return 0
        } catch {
            decrypted.cancel()
            return ffmpegErrorIO
        }
    }

    private func openHTTP(
        urlString: String,
        output: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>,
        flags: Int32
    ) -> Int32 {
        guard let resourceURL = URL(string: urlString) else { return ffmpegErrorInvalid }
        let isPlainRead = flags & 1 != 0 && flags & 2 == 0
        if isPlainRead, let hlsCache, let lease = try? hlsCache.leaseResource(at: resourceURL) {
            if let result = openLeased(lease: lease, output: output) {
                return result
            }
            // Cache failure must never make an otherwise playable stream
            // fail — fall through to the network exactly as the old
            // openChildIO did.
        }
        return openNetwork(url: resourceURL, output: output)
    }

    private func openLeased(
        lease: HLSPlaybackCacheLease,
        output: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>
    ) -> Int32? {
        do {
            // FFmpeg holds several segment contexts open at once, and a
            // whole segment fits under the per-resource cap, so these keep
            // the small buffer: there is no unstorable-read case to
            // amortize here.
            let io = try FFmpegCachedIO(source: lease.scope, bufferSize: 64 * 1_024)
            guard let ioContext = io.context else {
                lease.close()
                return nil
            }
            track(ioContext: ioContext, io: io, lease: lease, cancellable: nil)
            output.pointee = ioContext
            return 0
        } catch {
            lease.close()
            return nil
        }
    }

    private func openNetwork(
        url: URL,
        output: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>
    ) -> Int32 {
        let source = URLSessionByteSource(url: url, session: session, isInterrupted: isInterrupted, authorization: authorization)
        do {
            let io = try FFmpegCachedIO(source: source)
            guard let ioContext = io.context else {
                source.cancel()
                return ffmpegErrorIO
            }
            track(ioContext: ioContext, io: io, lease: nil, cancellable: source)
            output.pointee = ioContext
            return 0
        } catch {
            source.cancel()
            return ffmpegErrorIO
        }
    }

    /// file:, data:, and anything else libavformat still natively supports
    /// once the network stack is gone. avio_open2 cannot read the parent
    /// AVFormatContext, so the protocol allow/deny list and interrupt
    /// callback are copied across by hand, exactly as the policy this
    /// replaces did.
    private func openNative(
        context: UnsafeMutablePointer<AVFormatContext>?,
        output: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>?,
        url: UnsafePointer<CChar>?,
        flags: Int32,
        options: UnsafeMutablePointer<OpaquePointer?>?
    ) -> Int32 {
        var localOptions: OpaquePointer?
        defer { av_dict_free(&localOptions) }
        return withUnsafeMutablePointer(to: &localOptions) { local in
            let options = options ?? local
            for (key, value) in [
                ("protocol_whitelist", context?.pointee.protocol_whitelist),
                ("protocol_blacklist", context?.pointee.protocol_blacklist),
            ] {
                if let value {
                    let result = av_dict_set(options, key, value, 0)
                    guard result >= 0 else { return result }
                }
            }
            var interrupt = context?.pointee.interrupt_callback ?? AVIOInterruptCB()
            return avio_open2(output, url, flags, &interrupt, options)
        }
    }

    private func track(
        ioContext: UnsafeMutablePointer<AVIOContext>,
        io: FFmpegCachedIO,
        lease: HLSPlaybackCacheLease?,
        cancellable: (any TransportCancellable)?
    ) {
        stateLock.lock()
        tracked[UInt(bitPattern: ioContext)] = TrackedContext(io: io, lease: lease, cancellable: cancellable)
        stateLock.unlock()
    }

    private static func dictionaryValue(_ options: UnsafeMutablePointer<OpaquePointer?>?, _ key: String) -> String? {
        guard let entry = av_dict_get(options?.pointee, key, nil, 0), let value = entry.pointee.value else {
            return nil
        }
        return String(cString: value)
    }

    private static func decodeHex(_ string: String) -> Data? {
        guard string.count == 32 else { return nil }
        var data = Data(capacity: 16)
        var index = string.startIndex
        while index < string.endIndex {
            guard let next = string.index(index, offsetBy: 2, limitedBy: string.endIndex),
                  let byte = UInt8(string[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// A sequential-first URLSession byte source for one URL: streams the body
/// of a ranged GET and serves reads at the stream position; a read at
/// another offset restarts the request from there. Demuxing is sequential
/// almost all the time — this exists instead of a general random-access
/// loader (PlaybackCache's `URLSessionPlaybackRangeLoader`) because AVIO
/// already buffers ahead through `FFmpegCachedIO`, so paying per-request
/// HTTP overhead for every buffer refill would be wasteful; a genuine seek
/// just restarts the GET at the new offset.
nonisolated final class URLSessionByteSource: FFmpegByteSource, @unchecked Sendable {
    private static let retryDelays: [TimeInterval] = [0.25, 0.5, 1.0]
    private static let maxRetries = retryDelays.count
    private static let idleTimeout: TimeInterval = 15
    private static let backpressureHighWaterMark = 8 * 1_024 * 1_024
    private static let backpressureLowWaterMark = 2 * 1_024 * 1_024
    private static let discardCeiling: Int64 = 4 * 1_024 * 1_024

    private let url: URL
    private let session: URLSession
    private let isInterrupted: @Sendable () -> Bool
    private let priority: Float
    private let authorization: MediaRequestAuthorization?

    // Every mutable field below is read and written only while holding
    // `condition`; reads are called from the demuxer's serial queue while
    // delegate callbacks land on the session's own delegate queue.
    private let condition = NSCondition()
    private var activeTask: URLSessionDataTask?
    private var suspended = false
    private var currentPosition: Int64 = 0
    private var requestStreamOffset: Int64 = 0
    private var buffer = Data()
    private var discardRemaining: Int64 = 0
    private var responseValidated = false
    private var bodyEnded = false
    private var pendingError: Error?
    private var contentLengthStorage: Int64?
    private var lastDataAt = Date()
    private var retryCount = 0
    private var closed = false

    /// AVIO buffer sizing, per `FFmpegCachedIO`'s comment on why the buffer
    /// should track the cache's own request size.
    var requestSize: Int64 { 256 * 1_024 }

    var contentLength: Int64? {
        condition.lock()
        defer { condition.unlock() }
        return contentLengthStorage
    }

    init(
        url: URL,
        session: URLSession,
        isInterrupted: @escaping @Sendable () -> Bool,
        priority: Float = URLSessionTask.highPriority,
        authorization: MediaRequestAuthorization? = nil
    ) {
        self.url = url
        self.session = session
        self.isInterrupted = isInterrupted
        self.priority = priority
        self.authorization = authorization
    }

    deinit {
        cancel()
    }

    /// FFmpeg's `SEEK_SIZE`/anchor bookkeeping already lives in
    /// `FFmpegCachedIO` and the playback cache scopes; a plain network
    /// stream has no separate timeline to anchor.
    func setTimelineAnchor(byteOffset: Int64, timeFraction: Double) {}

    func cancel() {
        condition.lock()
        closed = true
        cancelActiveTaskLocked()
        condition.broadcast()
        condition.unlock()
    }

    func read(offset: Int64, length: Int, priority: Float) throws -> Data {
        guard length > 0 else { return Data() }
        condition.lock()
        guard !closed else {
            condition.unlock()
            throw FFmpegTransportError.closed
        }
        if activeTask == nil || offset != currentPosition {
            beginNewRequestLocked(at: offset, priority: priority)
        }
        let target = min(length, 64 * 1_024)
        while true {
            if closed {
                condition.unlock()
                throw FFmpegTransportError.closed
            }
            if buffer.count >= target || bodyEnded {
                break
            }
            if let error = pendingError {
                guard Self.isRetryable(error), retryCount < Self.maxRetries else {
                    condition.unlock()
                    throw error
                }
                let delay = Self.retryDelays[retryCount]
                retryCount += 1
                condition.unlock()
                Thread.sleep(forTimeInterval: delay)
                condition.lock()
                if closed {
                    condition.unlock()
                    throw FFmpegTransportError.closed
                }
                if isInterrupted() {
                    condition.unlock()
                    throw FFmpegTransportError.interrupted
                }
                resumeAfterErrorLocked(priority: priority)
                continue
            }
            if isInterrupted() {
                cancelActiveTaskLocked()
                condition.unlock()
                throw FFmpegTransportError.interrupted
            }
            if Date().timeIntervalSince(lastDataAt) > Self.idleTimeout {
                pendingError = FFmpegTransportError.timeout
                continue
            }
            condition.wait(until: Date().addingTimeInterval(0.1))
        }
        let take = min(length, buffer.count)
        let result: Data
        if take > 0 {
            result = buffer.prefix(take)
            buffer.removeFirst(take)
        } else {
            result = Data()
        }
        currentPosition += Int64(take)
        if buffer.count < Self.backpressureLowWaterMark, suspended, let task = activeTask {
            task.resume()
            suspended = false
        }
        condition.unlock()
        return result
    }

    // MARK: - State transitions (hold `condition`)

    private func beginNewRequestLocked(at offset: Int64, priority: Float) {
        cancelActiveTaskLocked()
        buffer.removeAll(keepingCapacity: true)
        currentPosition = offset
        retryCount = 0
        issueRequestLocked(at: offset, priority: priority)
    }

    private func resumeAfterErrorLocked(priority: Float) {
        cancelActiveTaskLocked()
        let resumeOffset = currentPosition + Int64(buffer.count)
        issueRequestLocked(at: resumeOffset, priority: priority)
    }

    private func issueRequestLocked(at streamOffset: Int64, priority: Float) {
        requestStreamOffset = streamOffset
        responseValidated = false
        bodyEnded = false
        pendingError = nil
        discardRemaining = 0
        lastDataAt = Date()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("bytes=\(streamOffset)-", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Moves the credential from the URL's query into this header for
        // the server's own origin — CFNetwork logs a failed task's full URL
        // (NSErrorFailingURLKey), and so would any diagnostic that prints
        // one. Never applies to a third-party origin.
        authorization?.apply(to: &request)
        let task = session.dataTask(with: request)
        task.priority = priority
        suspended = false
        activeTask = task
        (session.delegate as? FFmpegTransportSessionDelegate)?.register(self, for: task.taskIdentifier)
        task.resume()
    }

    private func cancelActiveTaskLocked() {
        guard let task = activeTask else { return }
        (session.delegate as? FFmpegTransportSessionDelegate)?.unregister(taskIdentifier: task.taskIdentifier)
        task.cancel()
        activeTask = nil
        suspended = false
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        switch error {
        case FFmpegTransportError.httpStatus(let code):
            return (500...599).contains(code)
        case FFmpegTransportError.timeout:
            return true
        default:
            return false
        }
    }

    private static func contentRangeStart(_ header: String) -> Int64? {
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        guard let dash = parts[1].firstIndex(of: "-") else { return nil }
        return Int64(parts[1][parts[1].startIndex..<dash])
    }

    private static func contentRangeTotal(_ header: String) -> Int64? {
        guard let total = header.split(separator: "/").last, total != "*" else { return nil }
        return Int64(total)
    }

    // MARK: - Delegate callbacks (arrive on the session's delegate queue)

    fileprivate func receive(
        response: URLResponse,
        taskIdentifier: Int,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        condition.lock()
        guard !closed, taskIdentifier == activeTask?.taskIdentifier else {
            condition.unlock()
            completionHandler(.cancel)
            return
        }
        let disposition = validateResponseLocked(response)
        condition.broadcast()
        condition.unlock()
        completionHandler(disposition)
    }

    fileprivate func receive(data: Data, taskIdentifier: Int) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed, taskIdentifier == activeTask?.taskIdentifier, responseValidated else { return }
        var chunk = data
        if discardRemaining > 0 {
            let drop = Int(min(Int64(chunk.count), discardRemaining))
            if drop > 0 { chunk.removeFirst(drop) }
            discardRemaining -= Int64(drop)
            guard !chunk.isEmpty else { return }
        }
        buffer.append(chunk)
        lastDataAt = Date()
        retryCount = 0
        if buffer.count > Self.backpressureHighWaterMark, let task = activeTask, !suspended {
            task.suspend()
            suspended = true
        }
        condition.broadcast()
    }

    fileprivate func complete(error: Error?, taskIdentifier: Int) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed, taskIdentifier == activeTask?.taskIdentifier else { return }
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                // Self-inflicted: a new read superseded this request, or
                // cancel() is tearing the source down. Neither is a failure.
            } else {
                pendingError = error
            }
        } else {
            bodyEnded = true
        }
        condition.broadcast()
    }

    /// HTTP 206 whose `Content-Range` starts at the requested offset is the
    /// happy path. HTTP 200 is accepted at offset 0; at a non-zero offset it
    /// means the server ignored `Range`, which is only survivable by
    /// discarding a bounded prefix — past that it is cheaper to fail than to
    /// silently redownload gigabytes.
    private func validateResponseLocked(_ response: URLResponse) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            pendingError = FFmpegTransportError.invalidResponse
            return .cancel
        }
        switch http.statusCode {
        case 206:
            guard let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                  Self.contentRangeStart(contentRange) == requestStreamOffset else {
                pendingError = FFmpegTransportError.invalidResponse
                return .cancel
            }
            contentLengthStorage = Self.contentRangeTotal(contentRange)
            responseValidated = true
            return .allow
        case 200:
            if requestStreamOffset == 0 {
                contentLengthStorage = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
                responseValidated = true
                return .allow
            } else if requestStreamOffset <= Self.discardCeiling {
                discardRemaining = requestStreamOffset
                responseValidated = true
                return .allow
            } else {
                pendingError = FFmpegTransportError.invalidResponse
                return .cancel
            }
        default:
            pendingError = FFmpegTransportError.httpStatus(http.statusCode)
            return .cancel
        }
    }
}

nonisolated extension URLSessionByteSource: TransportCancellable {}
nonisolated extension AES128CBCByteSource: TransportCancellable {}

/// AES-128-CBC with PKCS#7 padding over another source, sequential only —
/// what an HLS playlist's `EXT-X-KEY METHOD=AES-128` segment needs. Every
/// read must land exactly on the decrypted position because CBC's block
/// chaining make random access meaningless without re-deriving state from
/// the start of the segment; nothing in this engine needs to seek within an
/// encrypted segment anyway.
nonisolated final class AES128CBCByteSource: FFmpegByteSource, @unchecked Sendable {
    private let inner: URLSessionByteSource
    private let key: Data
    private let iv: Data
    private let lock = NSLock()

    private var cryptor: CCCryptorRef?
    private var innerPosition: Int64 = 0
    private var innerEnded = false
    private var finalized = false
    private var decryptedPosition: Int64 = 0
    private var buffer = Data()

    var requestSize: Int64 { inner.requestSize }
    var contentLength: Int64? { nil }

    init(inner: URLSessionByteSource, key: Data, iv: Data) {
        self.inner = inner
        self.key = key
        self.iv = iv
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    func setTimelineAnchor(byteOffset: Int64, timeFraction: Double) {}

    func cancel() {
        inner.cancel()
    }

    func read(offset: Int64, length: Int, priority: Float) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard offset == decryptedPosition else { throw FFmpegTransportError.invalidOffset }
        if cryptor == nil {
            try makeCryptorLocked()
        }
        while buffer.count < length, !finalized {
            if innerEnded {
                try finalizeLocked()
                break
            }
            let chunk = try inner.read(offset: innerPosition, length: Int(inner.requestSize), priority: priority)
            if chunk.isEmpty {
                innerEnded = true
                continue
            }
            innerPosition += Int64(chunk.count)
            try decryptLocked(chunk)
        }
        let take = min(length, buffer.count)
        let result = buffer.prefix(take)
        buffer.removeFirst(take)
        decryptedPosition += Int64(take)
        return Data(result)
    }

    private func makeCryptorLocked() throws {
        var created: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreate(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, key.count,
                    ivBytes.baseAddress,
                    &created
                )
            }
        }
        guard status == kCCSuccess, let created else { throw FFmpegTransportError.decodingFailed }
        cryptor = created
    }

    private func decryptLocked(_ chunk: Data) throws {
        guard let cryptor else { throw FFmpegTransportError.decodingFailed }
        var outBuffer = [UInt8](repeating: 0, count: chunk.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = chunk.withUnsafeBytes { input -> Int32 in
            CCCryptorUpdate(cryptor, input.baseAddress, chunk.count, &outBuffer, outBuffer.count, &outLength)
        }
        guard status == kCCSuccess else { throw FFmpegTransportError.decodingFailed }
        buffer.append(contentsOf: outBuffer.prefix(outLength))
    }

    private func finalizeLocked() throws {
        guard let cryptor else { throw FFmpegTransportError.decodingFailed }
        var outBuffer = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var outLength = 0
        let status = CCCryptorFinal(cryptor, &outBuffer, outBuffer.count, &outLength)
        guard status == kCCSuccess else { throw FFmpegTransportError.decodingFailed }
        buffer.append(contentsOf: outBuffer.prefix(outLength))
        finalized = true
    }
}
