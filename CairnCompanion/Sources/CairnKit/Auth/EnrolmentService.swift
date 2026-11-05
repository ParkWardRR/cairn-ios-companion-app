import CairnProtocol
import Foundation

public actor EnrolmentService {
    private let keyProvider: any KeyProvider
    private let identityStore: any IdentityStore

    public init(keyProvider: any KeyProvider, identityStore: any IdentityStore) {
        self.keyProvider = keyProvider
        self.identityStore = identityStore
    }

    public func enrol(
        code: String,
        deviceName: String,
        using client: CairnServerClient,
        localBaseURL: String,
        tailnetBaseURL: String
    ) async throws -> EnrolledIdentity {
        try await identityStore.save(state: .enrolling, identity: nil)

        let proofMessage = EnrolmentProof.message(
            code: code, publicKeyHex: keyProvider.publicKeyHex
        )
        let proofSignature: Data
        do {
            proofSignature = try keyProvider.sign(proofMessage)
        } catch {
            try await identityStore.save(state: .notEnrolled, identity: nil)
            throw EnrolmentError.proofSigningFailed
        }

        let result: EnrolmentResult
        do {
            result = try await client.enrol(
                code: EnrolmentProof.normalizedCode(code),
                name: deviceName,
                publicKey: keyProvider.publicKeyHex,
                proof: proofSignature
            )
        } catch {
            try await identityStore.save(state: .notEnrolled, identity: nil)
            throw error
        }

        let identity = EnrolledIdentity(
            clientID: result.clientID,
            role: result.role,
            scope: result.vehicles,
            instanceID: result.serverIdentity.instanceID,
            spkiSHA256: result.serverIdentity.spkiSHA256,
            localBaseURL: localBaseURL,
            tailnetBaseURL: tailnetBaseURL,
            publicKeyHex: keyProvider.publicKeyHex
        )
        try await identityStore.save(state: .enrolled, identity: identity)
        return identity
    }

    /// The stored identity, except that an enrolled one whose registered key is not the key this
    /// phone holds now is reported as `.needsReenrolment`: its requests could only fail with 401.
    public func loadIdentity() async -> (EnrolmentState, EnrolledIdentity?) {
        let (state, identity) = await identityStore.load()
        if state == .enrolled, let identity, identity.publicKeyHex != keyProvider.publicKeyHex {
            return (.needsReenrolment, identity)
        }
        return (state, identity)
    }

    public func markRevoked() async throws {
        let (_, identity) = await identityStore.load()
        try await identityStore.save(state: .revoked, identity: identity)
    }

    /// Forgets the enrolment, then replaces the key. The enrolment goes first so a key that
    /// cannot be replaced still leaves the phone able to enrol again, rather than stuck.
    public func reset() async throws {
        try await identityStore.clear()
        try keyProvider.deleteKey()
    }

    public func makeSigner() async -> (any RequestSigner)? {
        let (state, identity) = await loadIdentity()
        guard state == .enrolled, let identity else { return nil }
        return KeyProviderSigner(provider: keyProvider, clientID: identity.clientID)
    }
}

public enum EnrolmentError: Error, Sendable {
    case proofSigningFailed
    case notEnrolled
}
