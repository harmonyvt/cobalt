import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Plays a private library file straight from the server, without keeping it offline first.
///
/// A private original has no public link: its bytes come only from the keyed `GET /library/items/<id>/file`
/// (APP-API-CONTRACT 5b, Range honoured). AVPlayer cannot add the key to its own requests, so such a file gets a
/// `cobalt-stream://item/<id>.<ext>` URL, and its asset's resource loader fetches each byte range AVFoundation
/// asks for with the client's keyed request. Any other URL plays as a plain `AVURLAsset`.
@MainActor
public enum KeyedStream {
    public static let scheme = "cobalt-stream"

    /// Makes the keyed request for a library file; set by the live app (`AppModel.live`). Nil in previews and tests,
    /// where a stream URL fails to load and the hero keeps its poster.
    public static var requests: (@MainActor () -> (any RemoteFileRequests)?)?

    /// The stream URL of the private library file `itemID`. `ext` only names the file (the type comes from the
    /// server's answer).
    public nonisolated static func url(itemID: String, ext: String = "mp4") -> URL? {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "item"
        let safeExt = ext.isEmpty ? "mp4" : ext
        comps.path = "/\(itemID).\(safeExt)"
        return comps.url
    }

    /// The library file id a stream URL names; nil for any other URL.
    public nonisolated static func itemID(of url: URL) -> String? {
        guard url.scheme == scheme, url.host == "item" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// The asset for `url`: loader-backed for a stream URL, plain otherwise.
    public static func asset(_ url: URL) -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        guard let id = itemID(of: url), let requests = requests?(),
              let template = try? requests.urlRequest(for: .libraryItem(id: id)) else { return asset }
        let loader = KeyedStreamLoader(template: template)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        // the resource loader holds its delegate weakly: the asset keeps it alive
        objc_setAssociatedObject(asset, &KeyedStreamLoader.associationKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    /// A player item for `url` (see `asset(_:)`).
    public static func item(_ url: URL) -> AVPlayerItem { AVPlayerItem(asset: asset(url)) }
}

/// Answers AVFoundation's loading requests for one stream with ranged, keyed requests. Everything runs on `queue`
/// (the resource loader's and the URL session's delegate queue), so the state needs no lock.
final class KeyedStreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    nonisolated(unsafe) static var associationKey: UInt8 = 0

    let queue = DispatchQueue(label: "cobalt.keyed-stream")
    private let template: URLRequest
    private var session: URLSession!
    private var pending: [Int: AVAssetResourceLoadingRequest] = [:]
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(template: URLRequest) {
        self.template = template
        super.init()
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // the session holds its delegate strongly: a weak relay, so the loader goes (and ends the session) with its asset
        session = URLSession(configuration: config, delegate: WeakSessionDelegate(self), delegateQueue: ops)
    }

    deinit { session?.invalidateAndCancel() }

    /// The `Range` header for a loading request: the bytes it asks for, or the first two when it only wants the
    /// file's type and length.
    static func range(for request: AVAssetResourceLoadingRequest) -> String {
        guard let data = request.dataRequest else { return "bytes=0-1" }
        let start = data.currentOffset > 0 ? data.currentOffset : data.requestedOffset
        if data.requestsAllDataToEndOfResource { return "bytes=\(start)-" }
        let end = data.requestedOffset + Int64(data.requestedLength) - 1
        return "bytes=\(start)-\(max(start, end))"
    }

    /// The file's whole length from a `206`'s `content-range` (`bytes 0-1/12345`), else a `200`'s length.
    static func totalLength(of response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/"), let total = Int64(range[range.index(after: slash)...]) {
            return total
        }
        return response.statusCode == 200 && response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    /// The UTI AVFoundation wants for a MIME type (`video/mp4` → `public.mpeg-4`).
    static func contentType(of response: HTTPURLResponse, url: URL?) -> String? {
        if let mime = response.mimeType, let type = UTType(mimeType: mime) { return type.identifier }
        if let ext = url?.pathExtension, !ext.isEmpty, let type = UTType(filenameExtension: ext) { return type.identifier }
        return nil
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        var request = template
        request.setValue(Self.range(for: loadingRequest), forHTTPHeaderField: "Range")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        let task = session.dataTask(with: request)
        pending[task.taskIdentifier] = loadingRequest
        tasks[ObjectIdentifier(loadingRequest)] = task
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let task = tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) else { return }
        pending[task.taskIdentifier] = nil
        task.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let loading = pending[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            finish(dataTask, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: ["status": status]))
            completionHandler(.cancel)
            return
        }
        if let info = loading.contentInformationRequest {
            info.contentType = Self.contentType(of: http, url: loading.request.url)
            if let total = Self.totalLength(of: http) { info.contentLength = total }
            info.isByteRangeAccessSupported = http.statusCode == 206
        }
        if loading.dataRequest == nil {
            finish(dataTask, error: nil)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pending[dataTask.taskIdentifier]?.dataRequest?.respond(with: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let dataTask = task as? URLSessionDataTask else { return }
        if let error = error as? URLError, error.code == .cancelled { drop(dataTask); return }
        finish(dataTask, error: error)
    }

    private func finish(_ task: URLSessionDataTask, error: (any Error)?) {
        guard let loading = pending[task.taskIdentifier] else { return }
        drop(task)
        guard !loading.isFinished, !loading.isCancelled else { return }
        if let error { loading.finishLoading(with: error) } else { loading.finishLoading() }
    }

    private func drop(_ task: URLSessionDataTask) {
        if let loading = pending.removeValue(forKey: task.taskIdentifier) { tasks[ObjectIdentifier(loading)] = nil }
    }
}

/// Passes the session's callbacks to a loader it does not keep alive.
private final class WeakSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var target: KeyedStreamLoader?

    init(_ target: KeyedStreamLoader) { self.target = target }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let target else { completionHandler(.cancel); return }
        target.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        target?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        target?.urlSession(session, task: task, didCompleteWithError: error)
    }
}
