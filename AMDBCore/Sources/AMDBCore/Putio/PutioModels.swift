import Foundation

public struct PutioAccount: Decodable, Sendable, Equatable {
    public let username: String
    public let mail: String?
    public let userId: Int64?

    public init(username: String, mail: String? = nil, userId: Int64? = nil) {
        self.username = username; self.mail = mail; self.userId = userId
    }
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

public struct PutioFile: Decodable, Sendable, Hashable, Identifiable {
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

    public init(id: Int64, name: String, fileType: String? = nil, contentType: String? = nil, size: Int64? = nil,
                parentId: Int64? = nil, createdAt: String? = nil, updatedAt: String? = nil,
                firstAccessedAt: String? = nil, startFrom: Int? = nil, screenshot: String? = nil) {
        self.id = id; self.name = name; self.fileType = fileType; self.contentType = contentType; self.size = size
        self.parentId = parentId; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.firstAccessedAt = firstAccessedAt; self.startFrom = startFrom; self.screenshot = screenshot
    }

    public var isFolder: Bool { fileType == "FOLDER" }
    public var isVideo: Bool { fileType == "VIDEO" }
}

public struct PutioFileList: Decodable, Sendable, Equatable {
    public let parent: PutioFile?
    public let files: [PutioFile]

    public init(parent: PutioFile?, files: [PutioFile]) { self.parent = parent; self.files = files }
}

public struct PutioSubtitle: Decodable, Sendable, Equatable {
    public let key: String
    public let language: String?
    public let name: String?
    public let source: String?
}
