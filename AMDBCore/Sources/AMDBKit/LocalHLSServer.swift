import Foundation
import Network
import os

/// A tiny HTTP server on this device's Wi-Fi address that serves a few in-memory files (a playlist and a subtitle
/// file) to an AirPlay receiver, which fetches a stream's URLs itself and can't see anything inside the app.
/// Only GET and HEAD of the exact paths put here; every path sits under a random prefix nobody on the network can
/// guess. Accepting incoming connections needs no Local Network permission (Apple TN3179).
public final class LocalHLSServer: @unchecked Sendable {
    public struct File: Sendable {
        public let data: Data
        public let contentType: String
        public init(data: Data, contentType: String) { self.data = data; self.contentType = contentType }
    }

    static let log = Logger(subsystem: "app.amdb", category: "airplay")

    private let queue = DispatchQueue(label: "app.amdb.local-hls")
    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var listener: NWListener?
    private var port: UInt16?
    /// Paths the receiver asked for (DEBUG checks and tests).
    private var served: [String] = []

    public init() {}

    /// Starts listening (once) and returns the port.
    public func start() async throws -> UInt16 {
        if let port = lock.withLock({ port }) { return port }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [weak listener] state in
                let resume: Result<UInt16, Error>? = switch state {
                case .ready: listener?.port.map { .success($0.rawValue) } ?? .failure(NWError.posix(.EADDRNOTAVAIL))
                case let .failed(error): .failure(error)
                case .cancelled: .failure(CancellationError())
                default: nil
                }
                guard let resume, once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: resume)
            }
            listener.start(queue: queue)
        }
        lock.withLock {
            self.listener = listener
            self.port = port
        }
        Self.log.notice("local HLS server listening on port \(port)")
        return port
    }

    public func stop() {
        let listener = lock.withLock {
            defer { self.listener = nil; port = nil; files = [:] }
            return self.listener
        }
        listener?.cancel()
    }

    public var isRunning: Bool { lock.withLock { listener != nil } }

    /// Replaces everything served (paths start with "/").
    public func publish(_ newFiles: [String: File]) { lock.withLock { files = newFiles } }

    public var servedPaths: [String] { lock.withLock { served } }

    // MARK: HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: buffer[..<end.lowerBound], on: connection)
            } else if complete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        let requestLine = String(decoding: head, as: UTF8.self).split(separator: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : ""
        let file = lock.withLock { () -> File? in
            let file = files[path]
            if file != nil { served.append(path) }
            return file
        }
        let status: String
        var body = Data()
        var type = "text/plain"
        if method != "GET", method != "HEAD" {
            status = "405 Method Not Allowed"
        } else if let file {
            status = "200 OK"
            body = file.data
            type = file.contentType
        } else {
            status = "404 Not Found"
        }
        Self.log.debug("\(method, privacy: .public) \(path, privacy: .public) → \(status, privacy: .public)")
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        if method != "HEAD" { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// This device's address on the local network (Wi-Fi or Ethernet), which a TV on the same network can reach.
public enum LocalNetworkAddress {
    /// The first private IPv4 address of a broadcast-capable interface that's up. Cellular and VPN interfaces aren't
    /// broadcast-capable, so they're never picked (a TV can't reach them). Interface names aren't API, so no "en0".
    public static func current() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            candidates.append(String(cString: host))
        }
        return pick(candidates)
    }

    /// Private ranges first (home networks), then anything but link-local.
    static func pick(_ addresses: [String]) -> String? {
        addresses.first(where: isPrivate) ?? addresses.first { !$0.hasPrefix("169.254.") }
    }

    static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }
}
