import CairnProtocol
import Foundation

public protocol RequestSigner: Sendable {
    var clientID: String { get }
    var publicKeyX963: Data { get }
    func sign(_ data: Data) throws -> Data
}
