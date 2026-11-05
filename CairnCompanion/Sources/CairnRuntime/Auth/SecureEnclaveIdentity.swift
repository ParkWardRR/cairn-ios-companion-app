import CairnKit
import CairnProtocol
import CryptoKit
import Foundation
import Security

/// The device's enrolment key, kept across launches. A key that is not saved is a new key on the
/// next launch, which the server (it registered the old public key) answers with 401
/// signature_does_not_verify; the keys here are saved before they are ever used.
///
/// Both providers store their key as a generic-password item, the pattern CryptoKit documents:
/// a Secure Enclave key is stored as its opaque `dataRepresentation` (the private half never
/// leaves the chip), a software key as its raw scalar.
enum IdentityKeychain {
    static let service = "app.cairn.companion.identity"

    static func load(account: String) -> Data? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ] as CFDictionary, &out)
        return status == errSecSuccess ? out as? Data : nil
    }

    static func save(_ data: Data, account: String) throws {
        delete(account: account)
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }

    static func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
    }
}

public final class SecureEnclaveKeyProvider: KeyProvider, @unchecked Sendable {
    private static let account = "secure-enclave-p256"
    private let lock = NSLock()
    private var privateKey: SecureEnclave.P256.Signing.PrivateKey

    public var publicKeyX963: Data {
        lock.withLock { Data(privateKey.publicKey.x963Representation) }
    }

    public var publicKeyHex: String {
        publicKeyX963.map { String(format: "%02x", $0) }.joined()
    }

    public init() throws {
        if let data = IdentityKeychain.load(account: Self.account),
           let existing = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
            self.privateKey = existing
        } else {
            self.privateKey = try Self.makeAndSave()
        }
    }

    public func sign(_ data: Data) throws -> Data {
        try lock.withLock { try privateKey.signature(for: data).derRepresentation }
    }

    /// Forget this identity: the next key is a new one, saved at once.
    public func deleteKey() throws {
        let fresh = try Self.makeAndSave()
        lock.withLock { privateKey = fresh }
    }

    private static func makeAndSave() throws -> SecureEnclave.P256.Signing.PrivateKey {
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        try IdentityKeychain.save(key.dataRepresentation, account: account)
        return key
    }
}

/// For the simulator and any device where the Secure Enclave is unavailable: the same stable
/// identity, held in the Keychain instead of the chip.
public final class KeychainSoftwareKeyProvider: KeyProvider, @unchecked Sendable {
    private static let account = "software-p256"
    private let lock = NSLock()
    private var privateKey: P256.Signing.PrivateKey

    public var publicKeyX963: Data {
        lock.withLock { Data(privateKey.publicKey.x963Representation) }
    }

    public var publicKeyHex: String {
        publicKeyX963.map { String(format: "%02x", $0) }.joined()
    }

    public init() {
        if let data = IdentityKeychain.load(account: Self.account),
           let existing = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            self.privateKey = existing
        } else {
            let key = P256.Signing.PrivateKey()
            try? IdentityKeychain.save(key.rawRepresentation, account: Self.account)
            self.privateKey = key
        }
    }

    public func sign(_ data: Data) throws -> Data {
        try lock.withLock { try privateKey.signature(for: data).derRepresentation }
    }

    public func deleteKey() throws {
        let fresh = P256.Signing.PrivateKey()
        try IdentityKeychain.save(fresh.rawRepresentation, account: Self.account)
        lock.withLock { privateKey = fresh }
    }
}

public enum IdentityKeys {
    /// The Secure Enclave key where there is one, a Keychain-held key where there is not.
    public static func make() -> any KeyProvider {
        if SecureEnclave.isAvailable, let key = try? SecureEnclaveKeyProvider() { return key }
        return KeychainSoftwareKeyProvider()
    }
}
