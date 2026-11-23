import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Reads MP4 metadata in large HTTP ranges so AVFoundation can parse it from memory.
final class TapeLoader: NSObject, AVAssetResourceLoaderDelegate {
    /// AVAssetResourceLoader holds its delegate weakly. Keep this alongside the asset for its lifetime.
    struct Tape {
        let asset: AVURLAsset
        let url: URL
        private let loader: TapeLoader?

        var usesRanges: Bool { loader != nil }

        fileprivate init(url: URL, loader: TapeLoader? = nil, assetURL: URL? = nil) {
            self.url = url
            self.loader = loader
            asset = AVURLAsset(url: assetURL ?? url)
            if let loader {
                asset.resourceLoader.setDelegate(loader, queue: TapeRangeSession.shared.queue)
            }
        }
    }

    private struct Segment {
        let offset: Int64
        let data: Data

        var end: Int64 { offset + Int64(data.count) }
    }

    private struct Header {
        let origin: URL
        let length: Int64
        let segments: [Segment]
        var size: Int { segments.reduce(0) { $0 + $1.data.count } }
    }

    private final class HeaderCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [URL: Header] = [:]
        private var order: [URL] = []
        private var size = 0

        func get(_ key: URL) -> Header? {
            lock.withLock {
                guard let header = entries[key] else { return nil }
                order.removeAll { $0 == key }
                order.append(key)
                return header
            }
        }

        func insert(_ header: Header, for key: URL) {
            lock.withLock {
                removeEntry(key)
                guard header.size <= TapeLoader.cacheLimit else { return }
                while size + header.size > TapeLoader.cacheLimit, let first = order.first {
                    removeEntry(first)
                }
                entries[key] = header
                order.append(key)
                size += header.size
            }
        }

        func remove(_ key: URL) {
            lock.withLock { removeEntry(key) }
        }

        private func removeEntry(_ key: URL) {
            if let header = entries.removeValue(forKey: key) {
                size -= header.size
                order.removeAll { $0 == key }
            }
        }
    }

    private static let cacheLimit = 120_000_000
    private static let padding: Int64 = 256 * 1024
    private static let rangeLimit: Int64 = 60_000_000
    private static let cache = HeaderCache()

    private let canonical: URL
    private let origin: URL
    private let length: Int64
    private let contentType: UTType
    // Only accessed on TapeRangeSession's serial delegate queue.
    private var transfers: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var debugRequests = 0

    private init(canonical: URL, header: Header, contentType: UTType) {
        self.canonical = canonical
        origin = header.origin
        length = header.length
        self.contentType = contentType
    }

    static func nativeTape(url: URL) -> Tape { Tape(url: url) }

    static func prepare(canonical: URL, url: URL, moov: Int?) async throws -> Tape {
        let contentType: UTType
        switch canonical.pathExtension.lowercased() {
        case "mp4", "m4v": contentType = .mpeg4Movie
        case "mov": contentType = .quickTimeMovie
        default: return nativeTape(url: url)
        }

        guard url.scheme == "https",
              var custom = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else {
            return nativeTape(url: url)
        }
        custom.scheme = "spelunkr-https"
        guard let assetURL = custom.url else { return nativeTape(url: url) }

        do {
            try Task.checkCancellation()
            let header: Header
            if let existing = cache.get(canonical) {
                header = existing
                TuneLog.info("[loader] cached header: \(TuneLog.short(canonical))")
            } else {
                let began = Date.nowMs
                header = try await prefetch(url: url, moov: moov)
                try Task.checkCancellation()
                cache.insert(header, for: canonical)
                TuneLog.info("[loader] prefetched \(header.size) bytes in \(Int(Date.nowMs - began))ms: \(TuneLog.short(canonical))")
            }
            let loader = TapeLoader(canonical: canonical, header: header, contentType: contentType)
            return Tape(url: header.origin, loader: loader, assetURL: assetURL)
        } catch {
            try Task.checkCancellation()
            TuneLog.info("[loader] header unavailable, using AVFoundation: \(TuneLog.short(canonical)) \(error.localizedDescription)")
            return nativeTape(url: url)
        }
    }

    static func discardHeader(for canonical: URL) {
        // Large buffer deallocations should happen off the main thread too.
        TapeRangeSession.shared.queue.async { cache.remove(canonical) }
    }

    private enum Scan {
        case found
        case probe(offset: Int64)
        case readMoov(Range<Int64>)
    }

    private static func prefetch(url: URL, moov: Int?) async throws -> Header {
        let prefixLength = min(rangeLimit - padding, Int64(max(0, moov ?? 0))) + padding
        let (initialResponse, prefix) = try await TapeRangeSession.shared.fetch(
            url: url, range: 0..<prefixLength,
            prefixProbe: (Int(padding), { response, data in
                // Cancel the rest of a large prefix if a box header proves the moov is beyond it.
                if case .probe(let offset) = try scan(Segment(offset: 0, data: data), length: response.length) {
                    return offset >= response.end
                }
                return false
            })
        )
        let origin = initialResponse.url
        let total = initialResponse.length
        var segment = Segment(offset: 0, data: prefix)
        var segments: [Segment] = []

        // MP4 top-level sizes let us skip an mdat payload straight to a tail moov.
        for _ in 0..<8 {
            try Task.checkCancellation()
            let range: Range<Int64>
            switch try scan(segment, length: total) {
            case .found:
                segments.append(segment)
                return Header(origin: origin, length: total, segments: segments)
            case .probe(let offset):
                range = offset..<(offset + min(prefixLength, total - offset))
            case .readMoov(let moovRange):
                range = moovRange
            }
            // Keep enough of each probe for AVFoundation's box reads without retaining MBs of mdat.
            let retained = min(segment.data.count, Int(padding))
            let start = segment.data.startIndex
            let sample = segment.data.subdata(in: start..<start + retained)
            segments.append(Segment(offset: segment.offset, data: sample))
            let (_, bytes) = try await TapeRangeSession.shared.fetch(url: origin, range: range, length: total)
            segment = Segment(offset: range.lowerBound, data: bytes)
        }
        throw URLError(.cannotDecodeContentData)
    }

    private static func scan(_ segment: Segment, length: Int64) throws -> Scan {
        var offset = segment.offset
        let data = segment.data
        while offset < length {
            let index = data.startIndex + Int(offset - segment.offset)
            guard length - offset >= 8 else { throw URLError(.cannotDecodeContentData) }
            guard segment.end - offset >= 8 else { return .probe(offset: offset) }

            let sizeField = data[index..<index + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let isMoov = data[index + 4..<index + 8].elementsEqual([0x6D, 0x6F, 0x6F, 0x76])
            let size: UInt64
            let headerLength: UInt64
            switch sizeField {
            case 0:
                size = UInt64(length - offset)
                headerLength = 8
            case 1:
                guard length - offset >= 16 else { throw URLError(.cannotDecodeContentData) }
                guard segment.end - offset >= 16 else { return .probe(offset: offset) }
                size = data[index + 8..<index + 16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerLength = 16
            default:
                size = sizeField
                headerLength = 8
            }
            guard size >= headerLength, size <= UInt64(length - offset) else {
                throw URLError(.cannotDecodeContentData)
            }
            let end = offset + Int64(size)
            if isMoov {
                if end <= segment.end { return .found }
                guard size <= UInt64(rangeLimit) else { throw URLError(.dataLengthExceedsMaximum) }
                return .readMoov(offset..<end)
            }
            offset = end
            if offset >= segment.end, offset < length { return .probe(offset: offset) }
        }
        throw URLError(.cannotDecodeContentData)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = contentType.identifier
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let (requestedEnd, overflow) = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
        guard !overflow, data.requestedOffset >= 0, data.requestedLength >= 0 else {
            request.finishLoading(with: URLError(.badServerResponse))
            return true
        }
        let end = data.requestsAllDataToEndOfResource ? length : min(length, requestedEnd)
        debugRequests += 1
        let debug = debugRequests <= 16
        if debug {
            TuneLog.debug("[loader] request \(data.requestedOffset)..<\(end) \(data.requestsAllDataToEndOfResource ? "to EOF" : "bounded") on \(TuneLog.short(canonical))")
        }
        respond(to: request, from: max(data.requestedOffset, data.currentOffset), to: end, debug: debug)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        transfers.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }

    deinit {
        // The resource loader no longer calls the delegate once the last tape owner releases it.
        let pending = Array(transfers.values)
        if !pending.isEmpty { TapeRangeSession.shared.queue.async { pending.forEach { $0.cancel() } } }
    }

    private func respond(to request: AVAssetResourceLoadingRequest, from start: Int64, to end: Int64, debug: Bool) {
        guard !request.isCancelled, !request.isFinished, let dataRequest = request.dataRequest else { return }
        let cached = Self.cache.get(canonical)
        let segments = cached?.length == length ? cached?.segments ?? [] : []
        var offset = start
        while offset < end, let segment = segments.first(where: { $0.offset <= offset && offset < $0.end }) {
            let next = min(end, segment.end)
            let lower = segment.data.startIndex + Int(offset - segment.offset)
            let upper = lower + Int(next - offset)
            dataRequest.respond(with: segment.data[lower..<upper])
            offset = next
        }
        guard offset < end else {
            request.finishLoading()
            return
        }

        let next = segments.filter { $0.offset > offset }.map(\.offset).min() ?? end
        let stop = min(next, end)
        let key = ObjectIdentifier(request)
        let began = Date.nowMs
        let range = offset..<stop
        var first = true
        if debug { TuneLog.debug("[loader] GET \(range) for \(TuneLog.short(canonical))") }
        let task = TapeRangeSession.shared.start(
            url: origin, range: range, length: length,
            receive: { data in
                if debug && first {
                    first = false
                    TuneLog.debug("[loader] GET \(range) first bytes after \(Int(Date.nowMs - began))ms")
                }
                if !request.isCancelled { dataRequest.respond(with: data) }
            },
            complete: { [weak self] result in
                guard let self, self.transfers.removeValue(forKey: key) != nil, !request.isCancelled else { return }
                if debug { TuneLog.debug("[loader] GET \(range) finished in \(Int(Date.nowMs - began))ms") }
                switch result {
                case .success:
                    self.respond(to: request, from: stop, to: end, debug: debug)
                case .failure(let error):
                    request.finishLoading(with: error)
                }
            }
        )
        transfers[key] = task
    }
}

/// Validates Content-Range before accepting bytes and forwards media chunks as they arrive.
private final class TapeRangeSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Response {
        let url: URL
        let length: Int64
        let end: Int64
    }

    private struct Transfer {
        let range: Range<Int64>
        let length: Int64?
        let begin: ((Response, URLSessionDataTask) -> Void)?
        let receive: (Data) -> Void
        let complete: (Result<Response, Error>) -> Void
        var response: Response?
        var offset: Int64
    }

    static let shared = TapeRangeSession()
    let queue = DispatchQueue(label: "tv.spelunkr.tape-ranges", qos: .userInitiated)
    private var transfers: [Int: Transfer] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()

    func start(url: URL, range: Range<Int64>, length: Int64?,
               begin: ((Response, URLSessionDataTask) -> Void)? = nil,
               receive: @escaping (Data) -> Void,
               complete: @escaping (Result<Response, Error>) -> Void) -> URLSessionDataTask {
        dispatchPrecondition(condition: .onQueue(queue))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        transfers[task.taskIdentifier] = Transfer(range: range, length: length, begin: begin,
                                                   receive: receive, complete: complete, offset: range.lowerBound)
        task.resume()
        return task
    }

    private enum Event {
        case began(Response, URLSessionDataTask)
        case bytes(Data)
        case finished(Response)
    }

    func fetch(url: URL, range: Range<Int64>, length: Int64? = nil,
               prefixProbe: (minimum: Int, canStop: (Response, Data) throws -> Bool)? = nil) async throws -> (Response, Data) {
        let stream = AsyncThrowingStream<Event, Error> { continuation in
            queue.async {
                let task = self.start(
                    url: url, range: range, length: length,
                    begin: { continuation.yield(.began($0, $1)) },
                    receive: { continuation.yield(.bytes($0)) },
                    complete: { result in
                        switch result {
                        case .success(let response):
                            continuation.yield(.finished(response))
                            continuation.finish()
                        case .failure(let error):
                            continuation.finish(throwing: error)
                        }
                    }
                )
                continuation.onTermination = { reason in
                    if case .cancelled = reason { task.cancel() }
                }
            }
        }

        var bytes = Data()
        var started: (Response, URLSessionDataTask)?
        var probe = prefixProbe
        for try await event in stream {
            switch event {
            case .began(let response, let task):
                started = (response, task)
            case .bytes(let data):
                bytes.append(data)
                if let started, let pending = probe, bytes.count >= pending.minimum {
                    probe = nil
                    do {
                        if try pending.canStop(started.0, bytes) {
                            started.1.cancel()
                            return (started.0, bytes)
                        }
                    } catch {
                        started.1.cancel()
                        throw error
                    }
                }
            case .finished(let response):
                return (response, bytes)
            }
        }
        throw CancellationError()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let id = dataTask.taskIdentifier
        guard var transfer = transfers[id],
              let http = response as? HTTPURLResponse,
              let result = Self.parse(http, range: transfer.range, knownLength: transfer.length) else {
            completionHandler(.cancel)
            transfers.removeValue(forKey: id)?.complete(.failure(URLError(.badServerResponse)))
            return
        }
        transfer.response = result
        transfers[id] = transfer
        transfer.begin?(result, dataTask)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        guard var transfer = transfers[id], let response = transfer.response else { return }
        guard data.count <= response.end - transfer.offset else {
            dataTask.cancel()
            transfers.removeValue(forKey: id)?.complete(.failure(URLError(.badServerResponse)))
            return
        }
        transfer.offset += Int64(data.count)
        transfers[id] = transfer
        transfer.receive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        if let error {
            transfer.complete(.failure(error))
        } else if let response = transfer.response, transfer.offset == response.end {
            transfer.complete(.success(response))
        } else {
            transfer.complete(.failure(URLError(.badServerResponse)))
        }
    }

    private static func parse(_ response: HTTPURLResponse, range: Range<Int64>, knownLength: Int64?) -> Response? {
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard response.statusCode == 206, encoding == nil || encoding == "identity",
              let url = response.url, url.scheme == "https",
              let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let parts = value.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let bounds = parts[1].split(separator: "/")
        guard bounds.count == 2, let length = Int64(bounds[1]), length > 0,
              knownLength == nil || length == knownLength else { return nil }
        let ends = bounds[0].split(separator: "-")
        guard ends.count == 2, let start = Int64(ends[0]), let last = Int64(ends[1]),
              start == range.lowerBound, last >= start,
              last == min(range.upperBound, length) - 1 else { return nil }
        return Response(url: url, length: length, end: last + 1)
    }
}
