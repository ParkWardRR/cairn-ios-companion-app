import CairnProtocol
import CryptoKit
import Foundation

public protocol KeyProvider: Sendable {
    var publicKeyX963: Data { get }
    var publicKeyHex: String { get }
    func sign(_ data: Data) throws -> Data
    func deleteKey() throws
}

public struct KeyProviderSigner: RequestSigner, @unchecked Sendable {
    private let provider: any KeyProvider
    public let clientID: String
    public var publicKeyX963: Data { provider.publicKeyX963 }

    public init(provider: any KeyProvider, clientID: String) {
        self.provider = provider
        self.clientID = clientID
    }

    public func sign(_ data: Data) throws -> Data {
        try provider.sign(data)
    }
}

public final class SoftwareKeyProvider: KeyProvider, @unchecked Sendable {
    private let privateKey: P256.Signing.PrivateKey

    public var publicKeyX963: Data {
        Data(privateKey.publicKey.x963Representation)
    }

    public var publicKeyHex: String {
        publicKeyX963.map { String(format: "%02x", $0) }.joined()
    }

    public init(privateKey: P256.Signing.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).derRepresentation
    }

    public func deleteKey() throws {}
}
