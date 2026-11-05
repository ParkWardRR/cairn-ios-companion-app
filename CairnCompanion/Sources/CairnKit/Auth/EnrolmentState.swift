import CairnProtocol
import Foundation

public enum EnrolmentState: String, Codable, Sendable {
    case notEnrolled
    case enrolling
    case enrolled
    case revoked
    /// The identity on file was enrolled with a key this phone no longer holds (or one that was
    /// never saved), so every signed request would be refused. Only a fresh enrolment fixes it.
    case needsReenrolment
}

public struct EnrolledIdentity: Codable, Sendable {
    public var clientID: String
    public var role: String
    public var scope: [String]
    public var instanceID: String
    public var spkiSHA256: String
    public var localBaseURL: String
    public var tailnetBaseURL: String
    /// The public key (X9.63, lowercase hex) the server registered for this client. Absent on
    /// identities saved before the key was kept across launches; those cannot be trusted to match.
    public var publicKeyHex: String?

    public init(
        clientID: String, role: String, scope: [String],
        instanceID: String, spkiSHA256: String,
        localBaseURL: String, tailnetBaseURL: String,
        publicKeyHex: String? = nil
    ) {
        self.clientID = clientID
        self.role = role
        self.scope = scope
        self.instanceID = instanceID
        self.spkiSHA256 = spkiSHA256
        self.localBaseURL = localBaseURL
        self.tailnetBaseURL = tailnetBaseURL
        self.publicKeyHex = publicKeyHex
    }

    public var isAdmin: Bool { role == "admin" }
}
