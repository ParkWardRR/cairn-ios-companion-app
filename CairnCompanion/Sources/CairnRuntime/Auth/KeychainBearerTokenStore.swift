import CairnKit
import Foundation
import Security

/// The bearer token, in the Keychain.
///
/// It is a credential (`sync/v1` §2.3): never logged, never in UserDefaults, never parsed — the
/// app stores it and sends it and has no business knowing what is inside. The Keychain rather
/// than memory because the whole point of the token is that a **background** `URLSession`
/// upload, started before the app was suspended and finishing after it was gone, can still
/// present something: the Secure Enclave key cannot sign while the app is not running, and a
/// token in memory would not survive to be used.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: a background upload after a reboot needs
/// to read it before anyone unlocks the phone for the first time only in the sense that it must
/// work once they have, and it must never follow the phone to another device.
public actor KeychainBearerTokenStore: BearerTokenStore {
    private let service = "app.cairn.companion"
    private let account = "bearer-token"

    public init() {}

    public func load() -> BearerToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = try? JSONDecoder().decode(BearerToken.self, from: data) else { return nil }
        return token
    }

    public func save(_ token: BearerToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(baseQuery as CFDictionary)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
