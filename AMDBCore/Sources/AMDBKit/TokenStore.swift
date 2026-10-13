import Foundation
import Security

public enum TokenKey: String, CaseIterable, Sendable {
    case putio, tmdb, chill, mdblist

    /// TMDB, chill and MDBList tokens sync through iCloud Keychain so the Apple TV app can reuse them.
    var synchronizes: Bool { self != .putio }
}

public protocol TokenStore: Sendable {
    func read(_ key: TokenKey) -> String?
    func write(_ value: String?, for key: TokenKey)
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TokenKey: String]

    public init(_ values: [TokenKey: String] = [:]) { self.values = values }
    public func read(_ key: TokenKey) -> String? { lock.withLock { values[key] } }
    public func write(_ value: String?, for key: TokenKey) { lock.withLock { values[key] = value } }
}

public struct KeychainTokenStore: TokenStore {
    private let service: String

    public init(service: String = "app.amdb.tokens") { self.service = service }

    public func read(_ key: TokenKey) -> String? {
        var query = baseQuery(key)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String?, for key: TokenKey) {
        var deleteQuery = baseQuery(key)
        deleteQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(deleteQuery as CFDictionary)
        guard let value, !value.isEmpty else { return }

        var item = baseQuery(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if key.synchronizes { item[kSecAttrSynchronizable as String] = true }
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess, key.synchronizes {
            // Simulators and free provisioning can refuse synchronizable items; keep a device-only copy.
            item[kSecAttrSynchronizable as String] = false
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private func baseQuery(_ key: TokenKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }
}
