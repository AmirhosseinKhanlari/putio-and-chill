import AMDBCore
import Foundation

/// What the library reads in put.io: everything inside the Movies and TV Series folders at the top of put.io (and
/// inside the folders picked in Settings, wherever they are), plus videos sitting loose at the top. Other top-level
/// folders aren't read, so they never show up in Library, Recently Added, Continue Watching, Top Shelf, widgets or
/// Spotlight. Files still shows everything.
public struct LibraryScope: Sendable, Hashable {
    /// Top-level folders read whole, matched ignoring case and surrounding spaces.
    public var topLevelFolders: [String]
    /// Folders picked in Settings, read whole wherever they are (Get & Watch saves there).
    public var pickedFolders: [PutioFolderRef]

    public init(topLevelFolders: [String] = [DefaultFolders.movies, DefaultFolders.tv], pickedFolders: [PutioFolderRef] = []) {
        self.topLevelFolders = topLevelFolders
        self.pickedFolders = pickedFolders
    }

    public static let standard = LibraryScope()

    /// The default folders plus the ones the layout's Settings picked.
    public init(layout: FolderLayout) {
        self.init(pickedFolders: [layout.movies, layout.tv].compactMap { $0 })
    }

    /// Whether a folder directly at the top of put.io is read.
    public func includesTopLevelFolder(_ folder: PutioFile) -> Bool {
        topLevelFolders.contains { DefaultFolders.sameName($0, folder.name) } || pickedFolders.contains { $0.id == folder.id }
    }

    /// Picked folders the walk starts from besides the top of put.io (the name is the path's last part).
    var extraRoots: [(id: Int64, name: String)] {
        pickedFolders.map { ($0.id, $0.path.split(separator: "/").last.map(String.init) ?? $0.path) }
    }

    /// Saved with the cached library: a cache made with a different scope is read again from put.io at launch.
    public var signature: String {
        (topLevelFolders.map(DefaultFolders.key).sorted() + pickedFolders.map { "#\($0.id)" }.sorted()).joined(separator: "|")
    }
}
