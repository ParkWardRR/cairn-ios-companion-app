import CairnProtocol
import Foundation

/// One request, exactly as it goes on the wire. `target` is the path plus `?query` the server
/// sees and the signature covers; a transport appends it to its base URL and must not re-encode,
/// normalise or reorder it.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var target: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Header lookup is case-insensitive, as HTTP's is.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Requests carry credentials and bodies; the description is the method and the status, never
/// the headers, the target (it holds cursors) or the body (see spec section 11).
extension HTTPRequest: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "HTTPRequest(\(method))" }
    public var debugDescription: String { description }
}

extension HTTPResponse: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "HTTPResponse(\(status))" }
    public var debugDescription: String { description }
}

/// Why a request never produced a response. Carries no URL or message: those can hold cursors.
public enum TransportFailure: Sendable, Equatable {
    case offline
    case timedOut
    case tls
    case other
}

/// Thrown by a transport when no HTTP response came back. A response with any status, 4xx and
/// 5xx included, is a return value, not a throw.
public struct HTTPTransportError: Error, Sendable, Equatable {
    public var failure: TransportFailure
    public init(_ failure: TransportFailure) { self.failure = failure }
}

/// The only thing `CairnServerClient` knows about the network. The URLSession implementation
/// lives in CairnRuntime; tests serve recorded responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
