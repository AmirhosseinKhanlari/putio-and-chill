import Foundation

public struct PutioAccount: Decodable, Sendable, Equatable {
    public let username: String
    public let mail: String?
    public let userId: Int64?
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

public struct PutioFile: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let fileType: String?
    public let contentType: String?
    public let size: Int64?
    public let parentId: Int64?
    public let createdAt: String?
    public let updatedAt: String?
    public let startFrom: Int?
    public let screenshot: String?

    public var isFolder: Bool { fileType == "FOLDER" }
    public var isVideo: Bool { fileType == "VIDEO" }
}

public struct PutioFileList: Decodable, Sendable, Equatable {
    public let parent: PutioFile?
    public let files: [PutioFile]
}

public struct PutioSubtitle: Decodable, Sendable, Equatable {
    public let key: String
    public let language: String?
    public let name: String?
    public let source: String?
}
