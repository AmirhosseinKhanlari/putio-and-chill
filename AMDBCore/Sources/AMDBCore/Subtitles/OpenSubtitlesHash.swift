import Foundation

/// OpenSubtitles' file hash: file size plus the 64-bit little-endian words of the first and last 64 KB.
/// It identifies the exact release, so a matching subtitle is already in sync.
public enum OpenSubtitlesHash {
    public static let chunkSize = 65_536

    public static func compute(size: Int64, head: Data, tail: Data) -> String? {
        guard size >= Int64(chunkSize * 2), head.count == chunkSize, tail.count == chunkSize else { return nil }
        var hash = UInt64(bitPattern: size)
        for chunk in [head, tail] {
            chunk.withUnsafeBytes { buffer in
                for offset in stride(from: 0, to: chunkSize, by: 8) {
                    hash &+= UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    /// Reads the two chunks with HTTP range requests (put.io's download URL supports them).
    public static func compute(url: URL, size: Int64, transport: any HTTPTransport) async throws -> String? {
        guard size >= Int64(chunkSize * 2) else { return nil }
        let http = HTTPRequester(service: "putio", transport: transport)
        async let head = http.data(range(url, from: 0, to: Int64(chunkSize) - 1))
        async let tail = http.data(range(url, from: size - Int64(chunkSize), to: size - 1))
        return try await compute(size: size, head: head, tail: tail)
    }

    private static func range(_ url: URL, from: Int64, to: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        return request
    }
}
