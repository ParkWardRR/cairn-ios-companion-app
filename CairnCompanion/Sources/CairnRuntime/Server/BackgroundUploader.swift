import CairnKit
import CairnProtocol
import Foundation

/// Chunk uploads, handed to the system so they finish whether or not the app is still running.
///
/// A drive leaves the phone locked in a mount. iOS suspends what it likes, and a 64 KiB `PUT`
/// started in the foreground session dies with the app. A background `URLSessionConfiguration`
/// hands the transfer to `nsurlsessiond`, which finishes it, relaunches the app in the
/// background to say so, and retries it over a network change — which is exactly what
/// `sync/v1` §10 asks for, and why the chunk route takes a bearer token rather than a
/// signature: the Secure Enclave cannot sign while the app is not running.
///
/// Losing the answer to a chunk costs nothing. The relay is idempotent by construction: the
/// next offer tells the phone which chunks the server is still missing, and a chunk it already
/// has is simply not in the list. So a transfer whose completion arrives after the app was
/// killed is a chunk that does not need uploading again, and the durable row says where the
/// bundle got to regardless.
public final class BackgroundUploader: NSObject, @unchecked Sendable {
    public static let shared = BackgroundUploader(identifier: "app.cairn.companion.upload")

    /// Set by the app when iOS relaunches it to report finished transfers, and called once
    /// they have all been handled. Without it the system complains and throttles the app.
    public var backgroundEventsFinished: (() -> Void)?

    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<HTTPResponse, Error>] = [:]
    private var collected: [Int: Data] = [:]
    private var scratch: [Int: URL] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // A drive is where this matters, and a drive has no Wi-Fi. Discretionary would let iOS
        // hold the transfer until the phone is on power and Wi-Fi, which for a dongle that will
        // not free space until the receipt comes back means a card that fills up.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private let identifier: String

    init(identifier: String) {
        self.identifier = identifier
        super.init()
    }

    /// Hand the system one upload and wait for it, if the app is still here to wait.
    func send(_ request: HTTPRequest, baseURL: URL) async throws -> HTTPResponse {
        guard let url = URL(string: request.target, relativeTo: baseURL) else {
            throw HTTPTransportError(.other)
        }
        // A background upload must come from a file: the system has to be able to read the body
        // after the app is gone.
        let body = FileManager.default.temporaryDirectory
            .appendingPathComponent("cairn-chunk-\(UUID().uuidString)")
        do {
            try request.body.write(to: body, options: .atomic)
        } catch {
            throw HTTPTransportError(.other)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }

        let task = session.uploadTask(with: urlRequest, fromFile: body)
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                waiting[task.taskIdentifier] = continuation
                scratch[task.taskIdentifier] = body
            }
            task.resume()
        }
    }

    private func finish(_ id: Int, with result: Result<HTTPResponse, Error>) {
        let continuation: CheckedContinuation<HTTPResponse, Error>? = lock.withLock {
            let pending = waiting.removeValue(forKey: id)
            collected[id] = nil
            if let file = scratch.removeValue(forKey: id) { try? FileManager.default.removeItem(at: file) }
            return pending
        }
        continuation?.resume(with: result)
    }
}

extension BackgroundUploader: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { collected[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let failure: TransportFailure = switch (error as? URLError)?.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: .offline
            case .timedOut: .timedOut
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot: .tls
            default: .other
            }
            finish(task.taskIdentifier, with: .failure(HTTPTransportError(failure)))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            finish(task.taskIdentifier, with: .failure(HTTPTransportError(.other)))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let body = lock.withLock { collected[task.taskIdentifier] ?? Data() }
        finish(task.taskIdentifier, with: .success(
            HTTPResponse(status: http.statusCode, headers: headers, body: body)
        ))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundEventsFinished?()
            self?.backgroundEventsFinished = nil
        }
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // The same trust rule as the foreground session: the pin on the LAN host, ordinary
        // validation everywhere else. A background session that trusted more than the
        // foreground one would be a hole with no screen in front of it.
        PinnedCASessionDelegate().urlSession(
            session, didReceive: challenge, completionHandler: completionHandler
        )
    }
}

/// `BackgroundUploader` as an `HTTPTransport`, for `CairnServerClient`'s chunk route.
public struct BackgroundChunkTransport: HTTPTransport {
    private let baseURL: URL
    private let uploader: BackgroundUploader

    public init(baseURL: URL, uploader: BackgroundUploader = .shared) {
        self.baseURL = baseURL
        self.uploader = uploader
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await uploader.send(request, baseURL: baseURL)
    }
}
