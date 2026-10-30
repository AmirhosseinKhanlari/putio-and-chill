import Foundation
import Security

public enum TokenKey: String, CaseIterable, Sendable {
    case putio, tmdb, mdblist
    /// OpenSubtitles API key (overrides the built-in one) and optional account, which raises the daily download limit.
    case opensubtitles, opensubtitlesUsername, opensubtitlesPassword
    /// Link to the user's public IMDb watchlist or list (not a secret; synced so the Apple TV shows it too).
    case imdb

    /// TMDB and MDBList tokens sync through iCloud Keychain so the Apple TV app can reuse them.
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
        Keychain.read(service: service, account: key.rawValue).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func write(_ value: String?, for key: TokenKey) {
        Keychain.write(value.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, service: service, account: key.rawValue,
                       synchronizes: key.synchronizes)
    }

    /// Deletes an item saved under a key the app no longer has (on this device and, for synced items, through
    /// iCloud Keychain on the user's other devices too).
    public func removeRetired(account: String) {
        Keychain.write(nil, service: service, account: account, synchronizes: false)
    }
}

/// Generic password items, optionally shared with the user's other devices through iCloud Keychain.
enum Keychain {
    static func read(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Replaces the item (nil deletes it).
    static func write(_ data: Data?, service: String, account: String, synchronizes: Bool) {
        var deleteQuery = baseQuery(service: service, account: account)
        deleteQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(deleteQuery as CFDictionary)
        guard let data else { return }

        var item = baseQuery(service: service, account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if synchronizes { item[kSecAttrSynchronizable as String] = true }
        if SecItemAdd(item as CFDictionary, nil) != errSecSuccess, synchronizes {
            // Simulators and free provisioning can refuse synchronizable items; keep a device-only copy.
            item[kSecAttrSynchronizable as String] = false
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
