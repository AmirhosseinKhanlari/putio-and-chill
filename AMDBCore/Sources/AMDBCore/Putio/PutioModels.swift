import Foundation

public struct PutioAccount: Decodable, Sendable, Equatable {
    public struct Disk: Decodable, Sendable, Equatable {
        public let avail: Int64
        public let size: Int64
        public let used: Int64

        public init(avail: Int64, size: Int64, used: Int64) { self.avail = avail; self.size = size; self.used = used }
        public var fractionUsed: Double { size > 0 ? Double(used) / Double(size) : 0 }
    }

    public let username: String
    public let mail: String?
    public let userId: Int64?
    public let disk: Disk?
    /// Bytes in put.io's trash (deleted files waiting to expire).
    public let trashSize: Int64?

    public init(username: String, mail: String? = nil, userId: Int64? = nil, disk: Disk? = nil, trashSize: Int64? = nil) {
        self.username = username; self.mail = mail; self.userId = userId; self.disk = disk; self.trashSize = trashSize
    }
}

/// A deleted file in put.io's trash.
public struct PutioTrashFile: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let name: String
    public let fileType: String?
    public let size: Int64?
    public let deletedAt: String?
    public let expirationDate: String?

    public init(id: Int64, name: String, fileType: String? = nil, size: Int64? = nil, deletedAt: String? = nil,
                expirationDate: String? = nil) {
        self.id = id; self.name = name; self.fileType = fileType; self.size = size; self.deletedAt = deletedAt
        self.expirationDate = expirationDate
    }

    public var isFolder: Bool { fileType == "FOLDER" }
}

public struct PutioTrash: Decodable, Sendable, Equatable {
    public let files: [PutioTrashFile]
    public let trashSize: Int64?

    public init(files: [PutioTrashFile], trashSize: Int64?) { self.files = files; self.trashSize = trashSize }
}

public struct PutioTransfer: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String?
    public let status: String?
    public let percentDone: Int?
    public let downSpeed: Int64?
    public let peersConnected: Int?
    public let estimatedTime: Int64?
    public let downloaded: Int64?
    public let size: Int64?
    public let hash: String?
    public let fileId: Int64?
    public let saveParentId: Int64?
    public let errorMessage: String?

    public init(id: Int64, name: String? = nil, status: String? = nil, percentDone: Int? = nil, downSpeed: Int64? = nil,
                peersConnected: Int? = nil, estimatedTime: Int64? = nil, downloaded: Int64? = nil, size: Int64? = nil,
                hash: String? = nil, fileId: Int64? = nil, saveParentId: Int64? = nil, errorMessage: String? = nil) {
        self.id = id; self.name = name; self.status = status; self.percentDone = percentDone; self.downSpeed = downSpeed
        self.peersConnected = peersConnected; self.estimatedTime = estimatedTime; self.downloaded = downloaded
        self.size = size; self.hash = hash; self.fileId = fileId; self.saveParentId = saveParentId; self.errorMessage = errorMessage
    }
}

public struct PutioFile: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let name: String
    public let fileType: String?
    public let contentType: String?
    public let size: Int64?
    public let parentId: Int64?
    public let createdAt: String?
    public let updatedAt: String?
    public let firstAccessedAt: String?
    public let startFrom: Int?
    public let screenshot: String?
    /// put.io can't stream it to Apple devices as it is; an MP4 conversion is needed (only sent when asked for).
    public let needConvert: Bool?
    public let isMp4Available: Bool?

    public init(id: Int64, name: String, fileType: String? = nil, contentType: String? = nil, size: Int64? = nil,
                parentId: Int64? = nil, createdAt: String? = nil, updatedAt: String? = nil,
                firstAccessedAt: String? = nil, startFrom: Int? = nil, screenshot: String? = nil,
                needConvert: Bool? = nil, isMp4Available: Bool? = nil) {
        self.id = id; self.name = name; self.fileType = fileType; self.contentType = contentType; self.size = size
        self.parentId = parentId; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.firstAccessedAt = firstAccessedAt; self.startFrom = startFrom; self.screenshot = screenshot
        self.needConvert = needConvert; self.isMp4Available = isMp4Available
    }

    public var isFolder: Bool { fileType == "FOLDER" }
    /// put.io's type, or a video file extension (put.io can label a just-finished file before it has looked at it).
    public var isVideo: Bool {
        if fileType == "VIDEO" { return true }
        guard !isFolder else { return false }
        return Self.videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "wmv", "ts", "m2ts", "mpg", "mpeg",
                                               "webm", "flv", "divx", "xvid", "3gp", "ogv", "vob"]

    /// Whether it plays on Apple devices now (no conversion needed, or the MP4 is ready).
    public var isStreamable: Bool { needConvert != true || isMp4Available == true }
}

/// put.io's MP4 conversion of a video Apple devices can't play as it is. Read leniently: an unexpected status or a
/// fractional percentage must not make the whole answer unreadable.
public struct PutioMp4Status: Decodable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case notAvailable, inQueue, converting, completed, error
        case other(String)

        init(_ raw: String) {
            switch raw.uppercased() {
            case "NOT_AVAILABLE": self = .notAvailable
            case "IN_QUEUE", "QUEUED", "PREPARING": self = .inQueue
            case "CONVERTING": self = .converting
            case "COMPLETED", "DONE": self = .completed
            case "ERROR", "FAILED": self = .error
            default: self = .other(raw)
            }
        }
    }

    public let status: State
    public let percentDone: Int?

    public init(status: State, percentDone: Int? = nil) { self.status = status; self.percentDone = percentDone }

    enum CodingKeys: String, CodingKey { case status, percentDone }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = State((try? container.decode(String.self, forKey: .status)) ?? "")
        if let number = try? container.decode(Double.self, forKey: .percentDone) {
            percentDone = Int(number.rounded())
        } else if let text = try? container.decode(String.self, forKey: .percentDone), let number = Double(text) {
            percentDone = Int(number.rounded())
        } else {
            percentDone = nil
        }
    }
}

public struct PutioFileList: Decodable, Sendable, Equatable {
    public let parent: PutioFile?
    public let files: [PutioFile]

    public init(parent: PutioFile?, files: [PutioFile]) { self.parent = parent; self.files = files }
}

public struct PutioDeviceCode: Sendable, Equatable {
    public let code: String
    public let qrCodeURL: URL?

    public init(code: String, qrCodeURL: URL?) { self.code = code; self.qrCodeURL = qrCodeURL }
}

public struct PutioSubtitle: Codable, Sendable, Hashable, Identifiable {
    public let key: String
    /// Display name of the language ("English").
    public let language: String?
    /// ISO 639-2 code ("eng").
    public let languageCode: String?
    public let name: String?
    /// Where put.io got it: "mkv" (inside the file), "folder" (a file next to it), "opensubtitles".
    public let source: String?
    public var id: String { key }

    public init(key: String, language: String?, languageCode: String? = nil, name: String? = nil, source: String? = nil) {
        self.key = key; self.language = language; self.languageCode = languageCode; self.name = name; self.source = source
    }
}
