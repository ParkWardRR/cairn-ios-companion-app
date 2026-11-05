import CairnKit
import CairnProtocol
import Foundation

public actor KeychainIdentityStore: IdentityStore {
    private static let stateKey = "app.cairn.companion.enrolment-state"
    private static let identityKey = "app.cairn.companion.enrolled-identity"

    public init() {}

    public func load() -> (EnrolmentState, EnrolledIdentity?) {
        let state = loadState() ?? .notEnrolled
        let identity = loadIdentity()
        return (state, identity)
    }

    public func save(state: EnrolmentState, identity: EnrolledIdentity?) throws {
        try saveState(state)
        if let identity {
            try saveIdentity(identity)
        } else {
            deleteItem(Self.identityKey)
        }
    }

    public func clear() throws {
        deleteItem(Self.stateKey)
        deleteItem(Self.identityKey)
    }

    private func loadState() -> EnrolmentState? {
        guard let data = loadItem(Self.stateKey),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return EnrolmentState(rawValue: raw)
    }

    private func loadIdentity() -> EnrolledIdentity? {
        guard let data = loadItem(Self.identityKey) else { return nil }
        return try? JSONDecoder().decode(EnrolledIdentity.self, from: data)
    }

    private func saveState(_ state: EnrolmentState) throws {
        let data = Data(state.rawValue.utf8)
        try saveItem(data, key: Self.stateKey)
    }

    private func saveIdentity(_ identity: EnrolledIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        try saveItem(data, key: Self.identityKey)
    }

    private func loadItem(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key,
            kSecReturnData as String: true,
        ]
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess else { return nil }
        return ref as? Data
    }

    private func saveItem(_ data: Data, key: String) throws {
        deleteItem(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.saveFailed(status)
        }
    }

    private func deleteItem(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainStoreError: Error {
        case saveFailed(OSStatus)
    }
}
