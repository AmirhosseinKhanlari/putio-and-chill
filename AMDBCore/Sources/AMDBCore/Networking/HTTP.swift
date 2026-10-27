import Foundation
import os

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// It's been replaced by a fresh one (`RenewingTransport`): let go of its connections once in-flight requests end.
    func retire()
}

extension HTTPTransport {
    public func retire() {}
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.transport("non-HTTP response") }
        return (data, http)
    }

    public func retire() {
        if session !== URLSession.shared { session.finishTasksAndInvalidate() }
    }
}

/// Sends requests over its own connection and starts a fresh one when that stops answering.
///
/// One HTTP/2 connection carries every request to a host. If it dies silently (Wi-Fi to cellular, the phone asleep,
/// a router forgetting it) URLSession keeps queueing requests on it: each times out on its own, but the connection
/// can linger for many minutes, so every title page stays blank until the app restarts. A request that times out
/// or loses its connection here drops the whole session and, for a GET, is tried once more on a new one.
public final class RenewingTransport: HTTPTransport, @unchecked Sendable {
    static let log = Logger(subsystem: "app.amdb", category: "network")

    private let makeConnection: @Sendable () -> any HTTPTransport
    private let lock = NSLock()
    private var current: any HTTPTransport
    private var generation = 0

    public init(makeConnection: @escaping @Sendable () -> any HTTPTransport = { URLSessionTransport(session: RenewingTransport.apiSession()) }) {
        self.makeConnection = makeConnection
        current = makeConnection()
    }

    /// A session for small API calls: an answer that takes over 15 s isn't coming.
    public static func apiSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    /// The connection in use, and which one it is (they're numbered as they're made).
    public var connection: (generation: Int, transport: any HTTPTransport) { lock.withLock { (generation, current) } }

    /// Replaces connection `generation` with a fresh one, unless another request already did.
    public func renew(replacing generation: Int) {
        let stale: (any HTTPTransport)? = lock.withLock {
            guard generation == self.generation else { return nil }
            defer { current = makeConnection(); self.generation += 1 }
            return current
        }
        stale?.retire()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (generation, transport) = connection
        do {
            return try await transport.send(request)
        } catch let error as URLError where Self.isStale(error) {
            Self.log.notice("\(request.url?.host() ?? "?", privacy: .public) stopped answering (URLError \(error.code.rawValue)); starting a fresh connection")
            renew(replacing: generation)
            guard ["GET", "HEAD"].contains(request.httpMethod ?? "GET") else { throw error }
            let (retryGeneration, retry) = connection
            do {
                return try await retry.send(request)
            } catch let error as URLError where Self.isStale(error) {
                renew(replacing: retryGeneration)
                throw error
            }
        }
    }

    /// Errors that say the connection itself is gone, rather than the server answering or the device being offline.
    static func isStale(_ error: URLError) -> Bool {
        error.code == .timedOut || error.code == .networkConnectionLost
    }
}

extension URLSession {
    /// Hands redirects back as they are instead of following them: for sites that sometimes answer a page with a
    /// redirect to their home page, so that comes back as a 3xx error rather than a download of the home page.
    public static let noRedirects = URLSession(configuration: .default, delegate: NoRedirectsDelegate(), delegateQueue: nil)
}

final class NoRedirectsDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

public enum AppError: Error, Equatable, Sendable {
    case unauthorized(service: String)
    case http(service: String, status: Int)
    case decoding(service: String, detail: String)
    case transport(String)
    case timeout(service: String)
}

public struct HTTPRequester: Sendable {
    public let service: String
    public let transport: any HTTPTransport
    /// First wait after "429 Too Many Requests" when the server doesn't say how long (doubles each retry).
    let rateLimitBackoff: Duration

    public init(service: String, transport: any HTTPTransport, rateLimitBackoff: Duration = .seconds(1)) {
        self.service = service
        self.transport = transport
        self.rateLimitBackoff = rateLimitBackoff
    }

    /// Sends the request; on "429 Too Many Requests" (TMDB allows about 50 a second) waits as long as the server
    /// asks (Retry-After) or 1, 2, 4 s, up to three retries.
    public func data(_ request: URLRequest) async throws -> Data {
        for attempt in 0... {
            let (data, response) = try await send(request)
            if response.statusCode == 429, attempt < 3 {
                let asked = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).map { Duration.seconds(min($0, 10)) }
                try await Task.sleep(for: asked ?? rateLimitBackoff * (1 << attempt))
                continue
            }
            switch response.statusCode {
            case 200..<300: return data
            case 401: throw AppError.unauthorized(service: service)
            default: throw AppError.http(service: service, status: response.statusCode)
            }
        }
        fatalError("unreachable")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, HTTPURLResponse)
        do {
            result = try await transport.send(request)
        } catch let error as AppError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AppError.timeout(service: service)
        } catch {
            throw AppError.transport("\(service): \(error.localizedDescription)")
        }
        return result
    }

    public func decode<T: Decodable>(_ type: T.Type, _ request: URLRequest, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let body = try await data(request)
        do {
            return try decoder.decode(T.self, from: body)
        } catch {
            throw AppError.decoding(service: service, detail: String(describing: error))
        }
    }
}

extension JSONDecoder {
    public static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension URLRequest {
    public static func get(_ url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    public static func postJSON(_ url: URL, body: some Encodable, headers: [String: String] = [:]) throws -> URLRequest {
        var request = get(url, headers: headers)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    public static func postForm(_ url: URL, fields: [(String, String)], headers: [String: String] = [:]) -> URLRequest {
        var request = get(url, headers: headers)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&").utf8)
        return request
    }
}

let unreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

func formEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? value
}

/// Decodes an integer sent either as a JSON number or a numeric string (proto3 int64, EZTV, apibay).
public struct LossyInt64: Decodable, Sendable, Hashable {
    public let value: Int64?
    public init(_ value: Int64?) { self.value = value }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int64.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Int64(text)
        } else {
            value = nil
        }
    }
}
