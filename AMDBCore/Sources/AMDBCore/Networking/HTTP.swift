import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.transport("non-HTTP response") }
        return (data, http)
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

    public init(service: String, transport: any HTTPTransport) {
        self.service = service
        self.transport = transport
    }

    public func data(_ request: URLRequest) async throws -> Data {
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
        let (data, response) = result
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw AppError.unauthorized(service: service)
        default: throw AppError.http(service: service, status: response.statusCode)
        }
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
