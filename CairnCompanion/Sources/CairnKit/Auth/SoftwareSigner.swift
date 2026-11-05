import CairnProtocol
import CryptoKit
import Foundation

public final class SoftwareSigner: RequestSigner, @unchecked Sendable {
    private let privateKey: P256.Signing.PrivateKey
    public let clientID: String

    public var publicKeyX963: Data {
        Data(privateKey.publicKey.x963Representation)
    }

    public var publicKeyHex: String {
        publicKeyX963.map { String(format: "%02x", $0) }.joined()
    }

    public init(clientID: String, privateKey: P256.Signing.PrivateKey = .init()) {
        self.privateKey = privateKey
        self.clientID = clientID
    }

    public func sign(_ data: Data) throws -> Data {
        let signature = try privateKey.signature(for: data)
        return signature.derRepresentation
    }

    public func verify(_ signature: Data, for data: Data) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return privateKey.publicKey.isValidSignature(sig, for: data)
    }
}
