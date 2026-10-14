import AMDBCore
import AMDBKit
import Foundation

/// A put.io folder to open in the file manager.
struct FilesFolder: Hashable {
    let id: Int64
    let name: String

    static let root = FilesFolder(id: 0, name: "Files")
}

/// Files to move or copy, and from where.
struct DestinationRequest: Identifiable {
    enum Action { case move, copy }
    let action: Action
    let ids: Set<Int64>
    /// The folder they're in now (moving there does nothing).
    let source: Int64
    let id = UUID()
}

/// How put.io files look in the file manager (iPhone, iPad and Apple TV).
enum PutioFileStyle {
    static func symbol(_ fileType: String?) -> String {
        switch fileType {
        case "FOLDER": "folder.fill"
        case "VIDEO": "film"
        case "AUDIO": "music.note"
        case "IMAGE": "photo"
        case "PDF": "doc.richtext"
        case "ARCHIVE": "doc.zipper"
        case "TEXT": "doc.text"
        default: "doc"
        }
    }

    static func detail(_ file: PutioFile) -> String {
        [(file.size ?? 0) > 0 ? Format.bytes(file.size) : (file.isFolder ? "Empty" : nil), date(file.createdDate)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func detail(_ file: PutioTrashFile) -> String {
        var parts = [file.size.map { Format.bytes($0) }]
        if let deleted = PutioDate.parse(file.deletedAt) { parts.append("Deleted \(date(deleted) ?? "")") }
        if let expires = PutioDate.parse(file.expirationDate) {
            let days = max(0, Int(expires.timeIntervalSinceNow / 86_400))
            parts.append(days == 0 ? "Gone today" : "Gone in \(days) day\(days == 1 ? "" : "s")")
        }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    static func date(_ date: Date?) -> String? {
        date?.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func sortTitle(_ sort: FileSort) -> String {
        switch sort {
        case .name: "Name"
        case .newest: "Newest"
        case .largest: "Largest"
        }
    }

    /// "4 items · 12.3 GB"
    static func summary(_ files: [PutioFile]) -> String {
        let count = "\(files.count) item\(files.count == 1 ? "" : "s")"
        let bytes = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        return bytes > 0 ? "\(count) · \(Format.bytes(bytes))" : count
    }
}
