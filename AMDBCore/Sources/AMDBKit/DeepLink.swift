import AMDBCore
import Foundation

/// `amdb://` links used by widgets, Live Activities and Siri to open a specific screen.
public enum DeepLink: Equatable, Sendable {
    case play(fileID: Int64)
    case title(tmdbID: Int, kind: MediaKind)
    case library

    public var url: URL {
        switch self {
        case let .play(fileID): URL(string: "amdb://play/\(fileID)")!
        case let .title(tmdbID, kind): URL(string: "amdb://title/\(kind.rawValue)/\(tmdbID)")!
        case .library: URL(string: "amdb://library")!
        }
    }

    public init?(url: URL) {
        guard url.scheme == "amdb", let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "play":
            guard parts.count == 1, let id = Int64(parts[0]) else { return nil }
            self = .play(fileID: id)
        case "title":
            guard parts.count == 2, let kind = MediaKind(rawValue: parts[0]), kind != .person, let id = Int(parts[1]) else { return nil }
            self = .title(tmdbID: id, kind: kind)
        case "library":
            self = .library
        default:
            return nil
        }
    }
}
