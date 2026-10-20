import Foundation

/// What's inside a video file, as put.io describes it: the codecs of its video and audio streams and the container.
/// Read from `GET files/{id}?codecs=1&media_info=1&video_metadata=1` (put.io's own SDK asks for the same fields).
/// Every part is optional and read leniently: put.io leaves fields out for files it hasn't looked at yet, and an
/// unknown shape must never stop a video from playing (the player then just tries Apple's first).
public struct PutioMediaInfo: Sendable, Equatable {
    /// Video codec names in FFmpeg's spelling ("h264", "hevc", "mpeg4"), lowercased.
    public var videoCodecs: [String]
    /// Audio codec names in FFmpeg's spelling ("aac", "eac3", "dts"), lowercased.
    public var audioCodecs: [String]
    /// The container FFmpeg opened ("matroska,webm", "avi"), when put.io says.
    public var container: String?
    /// put.io can't stream it to Apple devices as it is (an MP4 conversion is needed).
    public var needConvert: Bool?
    public var isMp4Available: Bool?

    public init(videoCodecs: [String] = [], audioCodecs: [String] = [], container: String? = nil,
                needConvert: Bool? = nil, isMp4Available: Bool? = nil) {
        self.videoCodecs = videoCodecs; self.audioCodecs = audioCodecs; self.container = container
        self.needConvert = needConvert; self.isMp4Available = isMp4Available
    }

    /// Nothing known about the streams.
    public var isEmpty: Bool { videoCodecs.isEmpty && audioCodecs.isEmpty }
}

extension PutioMediaInfo: Decodable {
    enum CodingKeys: String, CodingKey {
        case mediaInfo, videoMetadata, contentTypeAndCodecs, needConvert, isMp4Available
    }

    /// Decodes a put.io file object (keys already converted from snake_case).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let media = try? c.decodeIfPresent(MediaInfo.self, forKey: .mediaInfo)
        var video: [String] = []
        var audio: [String] = []
        for stream in media?.streams ?? [] {
            guard let name = stream.codecName?.lowercased(), !name.isEmpty else { continue }
            switch stream.codecType?.lowercased() {
            case "video"?: if !video.contains(name) { video.append(name) }
            case "audio"?: if !audio.contains(name) { audio.append(name) }
            default: break
            }
        }
        // Older files only carry video_metadata (one codec) or the MIME type with RFC 6381 codecs.
        if video.isEmpty, let codec = (try? c.decodeIfPresent(VideoMetadata.self, forKey: .videoMetadata))?.codec?.lowercased(),
           !codec.isEmpty {
            video.append(codec)
        }
        if let mime = try? c.decodeIfPresent(String.self, forKey: .contentTypeAndCodecs) {
            let listed = Self.codecs(fromMIME: mime)
            if video.isEmpty { video = Self.unique(listed.filter { $0.kind == .video }.map(\.name)) }
            if audio.isEmpty { audio = Self.unique(listed.filter { $0.kind == .audio }.map(\.name)) }
        }
        videoCodecs = video
        audioCodecs = audio
        container = media?.format?.name
        needConvert = try? c.decodeIfPresent(Bool.self, forKey: .needConvert)
        isMp4Available = try? c.decodeIfPresent(Bool.self, forKey: .isMp4Available)
    }

    struct MediaInfo: Decodable {
        struct Format: Decodable { let name: String? }
        struct Stream: Decodable {
            let codecName: String?
            let codecType: String?
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                codecName = try? c.decodeIfPresent(String.self, forKey: .codecName)
                codecType = try? c.decodeIfPresent(String.self, forKey: .codecType)
            }
            enum CodingKeys: String, CodingKey { case codecName, codecType }
        }
        let format: Format?
        let streams: [Stream]?
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try? c.decodeIfPresent(Format.self, forKey: .format)
            // One unreadable stream drops only itself, not the list.
            streams = (try? c.decodeIfPresent([Lenient<Stream>].self, forKey: .streams))?.compactMap(\.value)
        }
        enum CodingKeys: String, CodingKey { case format, streams }
    }

    struct VideoMetadata: Decodable { let codec: String? }

    struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
    }

    enum Kind { case video, audio }

    private static func unique(_ names: [String]) -> [String] {
        names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// `video/mp4; codecs="avc1.640028, mp4a.40.2"` → h264 (video), aac (audio). Unknown tags are skipped.
    static func codecs(fromMIME mime: String) -> [(name: String, kind: Kind)] {
        guard let range = mime.range(of: "codecs=", options: .caseInsensitive) else { return [] }
        let list = mime[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ;"))
        return list.split(separator: ",").compactMap { raw in
            let tag = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).split(separator: ".").first.map(String.init)?.lowercased() ?? ""
            return rfc6381[tag]
        }
    }

    private static let rfc6381: [String: (name: String, kind: Kind)] = [
        "avc1": ("h264", .video), "avc3": ("h264", .video), "hvc1": ("hevc", .video), "hev1": ("hevc", .video),
        "dvh1": ("hevc", .video), "dvhe": ("hevc", .video), "av01": ("av1", .video), "vp08": ("vp8", .video),
        "vp09": ("vp9", .video), "mp4v": ("mpeg4", .video), "mp4a": ("aac", .audio), "ac-3": ("ac3", .audio),
        "ec-3": ("eac3", .audio), "opus": ("opus", .audio), "flac": ("flac", .audio), "alac": ("alac", .audio),
        "dtsc": ("dts", .audio), "dtsh": ("dts", .audio), "dtsl": ("dts", .audio), "dtse": ("dts", .audio),
        "dtsx": ("dts", .audio), "mlpa": ("truehd", .audio), "vorbis": ("vorbis", .audio),
    ]
}
