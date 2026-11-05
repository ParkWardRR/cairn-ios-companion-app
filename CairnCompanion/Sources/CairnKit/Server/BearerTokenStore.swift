import CairnProtocol
import Foundation

/// A minted bearer token and when it stops working. The token is opaque: it is stored and sent,
/// never parsed. It is a credential (spec section 2.3): Keychain only, never logged.
public struct BearerToken: Sendable, Equatable, Codable {
    public var token: String
    public var expiresAt: Date

    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

extension BearerToken: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "BearerToken(expires: \(expiresAt))" }
    public var debugDescription: String { description }
}

/// Where the client keeps its token between calls. CairnRuntime provides the Keychain one, so a
/// background `URLSession` task created ahead of time can still find it.
public protocol BearerTokenStore: Sendable {
    func load() async -> BearerToken?
    func save(_ token: BearerToken) async
    func clear() async
}

public actor InMemoryBearerTokenStore: BearerTokenStore {
    private var current: BearerToken?

    public init(_ initial: BearerToken? = nil) { current = initial }

    public func load() -> BearerToken? { current }
    public func save(_ token: BearerToken) { current = token }
    public func clear() { current = nil }
}
