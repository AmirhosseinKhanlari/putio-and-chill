import Foundation

/// Where the app keeps its files. Apple TV apps may only write to Caches (Application Support isn't writable
/// there), so tvOS uses Caches; elsewhere Application Support, which is kept and backed up.
public enum StorageLocation {
    public static var directory: URL {
        #if os(tvOS)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "AMDB")
        #else
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "AMDB")
        #endif
    }
}
