import Foundation

nonisolated enum DownloadLimit {
    static let subtitle = 8 * 1_024 * 1_024
    static let artwork = 16 * 1_024 * 1_024
}

nonisolated enum DownloadFailure: Error, Equatable {
    case invalidResponse
    case httpStatus(Int, Data)
    case tooLarge(Int)
    case unexpectedContentType
    case truncated
    case unsafeRedirect
}

/// A reusable URLSession whose delegate bounds bytes before accumulating
/// them. Content-Length is an early check, never the authority for the cap:
/// chunked and decompressed response bytes are checked on every callback.
nonisolated final class BoundedDownload: Sendable {
    static let shared = BoundedDownload()

    enum Content: Sendable { case subtitle, image, bytes }

    private let delegate: DownloadDelegate
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        delegate = DownloadDelegate()
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest, limit: Int, content: Content,
              statusCodes: Set<Int> = [200]) async throws -> Data {
        guard limit > 0, let url = request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw DownloadFailure.invalidResponse
        }
        let transfer = DownloadTransfer(limit: limit, content: content, statusCodes: statusCodes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.insert(transfer, for: task.taskIdentifier)
                transfer.start(task: task, continuation: continuation) { [delegate] in
                    delegate.remove(task.taskIdentifier)
                }
            }
        } onCancel: {
            transfer.finish(.failure(CancellationError()))
        }
    }

    func data(from url: URL, limit: Int, content: Content) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        return try await data(for: request, limit: limit, content: content)
    }
}

/// URLSession owns this delegate, but the delegate does not own its session.
/// Transfers leave the locked map on every completion and cancellation path.
private nonisolated final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transfers: [Int: DownloadTransfer] = [:]

    func insert(_ transfer: DownloadTransfer, for id: Int) { lock.withLock { transfers[id] = transfer } }
    func remove(_ id: Int) { _ = lock.withLock { transfers.removeValue(forKey: id) } }
    private func transfer(_ id: Int) -> DownloadTransfer? { lock.withLock { transfers[id] } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(transfer(dataTask.taskIdentifier)?.receive(response) == true ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(dataTask.taskIdentifier)?.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(task.taskIdentifier)?.complete(error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = response.url, let to = request.url,
              ["http", "https"].contains(to.scheme?.lowercased() ?? ""),
              !(from.scheme?.lowercased() == "https" && to.scheme?.lowercased() != "https") else {
            transfer(task.taskIdentifier)?.finish(.failure(DownloadFailure.unsafeRedirect))
            completionHandler(nil)
            return
        }
        // URLSession handles normal redirects and platform TLS trust. Never
        // manually copy Authorization or API keys to the redirected request.
        completionHandler(request)
    }
}

/// Only the fields under `lock` are mutable. Resume, cancellation and map
/// removal happen outside the lock and exactly once, including cancellation
/// before the URLSession task/continuation has been installed.
private nonisolated final class DownloadTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let content: BoundedDownload.Content
    private let statusCodes: Set<Int>
    private var response: HTTPURLResponse?
    private var data = Data()
    private var completed = false
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionTask?
    private var onFinish: (@Sendable () -> Void)?

    init(limit: Int, content: BoundedDownload.Content, statusCodes: Set<Int>) {
        self.limit = limit
        self.content = content
        self.statusCodes = statusCodes
    }

    func start(task: URLSessionTask, continuation: CheckedContinuation<Data, Error>,
               onFinish: @escaping @Sendable () -> Void) {
        lock.lock()
        if completed {
            lock.unlock()
            onFinish()
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.task = task
        self.continuation = continuation
        self.onFinish = onFinish
        task.resume()
        lock.unlock()
    }

    func receive(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(DownloadFailure.invalidResponse))
            return false
        }
        let active = lock.withLock { () -> Bool in
            guard !completed else { return false }
            self.response = http
            return true
        }
        guard active else { return false }
        // Retain a small error body for Jellyfin's useful provider messages,
        // but authentication/permission failures need no body or extra wait.
        if !statusCodes.contains(http.statusCode) {
            if [401, 403, 429].contains(http.statusCode) {
                finish(.failure(DownloadFailure.httpStatus(http.statusCode, Data())))
                return false
            }
            return true
        }
        if http.expectedContentLength > Int64(limit) {
            finish(.failure(DownloadFailure.tooLarge(limit)))
            return false
        }
        let mime = http.mimeType?.lowercased()
        let isHTMLOrJSON = mime == "text/html" || mime == "application/xhtml+xml"
            || mime == "application/json" || mime == "application/problem+json"
        if content != .bytes, isHTMLOrJSON {
            finish(.failure(DownloadFailure.unexpectedContentType))
            return false
        }
        return true
    }

    func receive(_ chunk: Data) {
        lock.lock()
        guard !completed, let response else { lock.unlock(); return }
        if !statusCodes.contains(response.statusCode) {
            let cap = 16 * 1_024
            data.append(chunk.prefix(max(0, cap - data.count)))
            let body = data
            lock.unlock()
            if body.count >= cap { finish(.failure(DownloadFailure.httpStatus(response.statusCode, body))) }
            return
        }
        guard chunk.count <= limit - data.count else {
            lock.unlock()
            finish(.failure(DownloadFailure.tooLarge(limit)))
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func complete(_ error: Error?) {
        let result: Result<Data, Error> = lock.withLock {
            guard let response else { return .failure(error ?? DownloadFailure.invalidResponse) }
            if !statusCodes.contains(response.statusCode) {
                return .failure(DownloadFailure.httpStatus(response.statusCode, data))
            }
            if let error { return .failure(error) }
            // Content-Length counts encoded bytes when compression is used.
            if response.value(forHTTPHeaderField: "Content-Encoding") == nil,
               response.expectedContentLength >= 0, response.expectedContentLength != Int64(data.count) {
                return .failure(DownloadFailure.truncated)
            }
            return .success(data)
        }
        finish(result)
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        let task = self.task
        let onFinish = self.onFinish
        self.continuation = nil
        self.task = nil
        self.onFinish = nil
        data = Data()
        lock.unlock()
        onFinish?()
        if case .failure = result { task?.cancel() }
        continuation?.resume(with: result)
    }
}
