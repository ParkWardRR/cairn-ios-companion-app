import CairnKit
import CairnProtocol
import Foundation

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = CairnURLSession.shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.target, relativeTo: baseURL) else {
            throw HTTPTransportError(.other)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if !request.body.isEmpty {
            urlRequest.httpBody = request.body
        }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw HTTPTransportError(.offline)
            case .timedOut:
                throw HTTPTransportError(.timedOut)
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                throw HTTPTransportError(.tls)
            default:
                throw HTTPTransportError(.other)
            }
        } catch {
            throw HTTPTransportError(.other)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw HTTPTransportError(.other)
        }

        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k] = v
            }
        }

        return HTTPResponse(status: httpResponse.statusCode, headers: headers, body: data)
    }
}
