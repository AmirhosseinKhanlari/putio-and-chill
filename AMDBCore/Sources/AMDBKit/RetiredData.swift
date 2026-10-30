import Foundation

/// Things older versions saved for features that are gone: removed once, at launch.
public enum RetiredData {
    /// Keychain accounts of removed sign-ins (the old chill release-search account).
    public static let tokenAccounts = ["chill"]
    /// Files in the app's storage folder that nothing reads any more (the old Latest lists snapshot).
    public static let fileNames = ["chill-feed.json"]
    static let doneKey = "amdb.retiredDataRemoved.1"

    /// Deletes the retired Keychain items and files; once the Keychain delete has worked, later launches do nothing.
    public static func removeOnce(defaults: UserDefaults = .standard, directory: URL = StorageLocation.directory,
                                  removeToken: (String) -> Bool = { KeychainTokenStore().removeRetired(account: $0) }) {
        guard !defaults.bool(forKey: doneKey) else { return }
        var allGone = true
        for account in tokenAccounts where !removeToken(account) { allGone = false }
        for name in fileNames { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
        // A refused delete (the Keychain can be locked early after a restart) is tried again next launch.
        if allGone { defaults.set(true, forKey: doneKey) }
    }
}
