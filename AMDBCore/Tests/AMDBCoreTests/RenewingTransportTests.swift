import AMDBCore
import Foundation
import Testing

@Suite struct RenewingTransportTests {
    /// One connection: answers with `handler`, counts its requests, and remembers being retired.
    final class Connection: HTTPTransport, @unchecked Sendable {
        let lock = NSLock()
        let handler: @Sendable (URLRequest) throws -> Int
        private var _requests = 0
        private var _retired = false
        var requests: Int { lock.withLock { _requests } }
        var retired: Bool { lock.withLock { _retired } }

        init(_ handler: @escaping @Sendable (URLRequest) throws -> Int) { self.handler = handler }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { _requests += 1 }
            let status = try handler(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        func retire() { lock.withLock { _retired = true } }
    }

    /// Hands out the given connections in order (the last one again once they run out).
    final class Connections: @unchecked Sendable {
        let lock = NSLock()
        let all: [Connection]
        private var _made = 0
        var made: Int { lock.withLock { _made } }
        init(_ all: [Connection]) { self.all = all }
        func next() -> any HTTPTransport { lock.withLock { defer { _made += 1 }; return all[min(_made, all.count - 1)] } }
    }

    let get = URLRequest(url: URL(string: "https://api.example.test/3/tv/1")!)

    /// A connection that stopped answering (requests time out) is dropped, and the request is tried again on a new one.
    @Test func timeoutStartsAFreshConnectionAndRetries() async throws {
        let dead = Connection { _ in throw URLError(.timedOut) }
        let fresh = Connection { _ in 200 }
        let connections = Connections([dead, fresh])
        let transport = RenewingTransport(makeConnection: connections.next)

        let (_, response) = try await transport.send(get)
        #expect(response.statusCode == 200)
        #expect(dead.retired)
        #expect(connections.made == 2)

        // Later requests go straight to the new connection: the dead one is never used again.
        _ = try await transport.send(get)
        #expect(dead.requests == 1)
        #expect(fresh.requests == 2)
    }

    @Test func lostConnectionStartsAFreshOne() async throws {
        let lost = Connection { _ in throw URLError(.networkConnectionLost) }
        let fresh = Connection { _ in 200 }
        let transport = RenewingTransport(makeConnection: Connections([lost, fresh]).next)
        #expect(try await transport.send(get).1.statusCode == 200)
        #expect(lost.retired)
    }

    /// Sending a POST twice could do it twice (two transfers): the connection is renewed but the error stands.
    @Test func postIsNotRetried() async throws {
        let dead = Connection { _ in throw URLError(.timedOut) }
        let fresh = Connection { _ in 200 }
        var post = get
        post.httpMethod = "POST"
        let transport = RenewingTransport(makeConnection: Connections([dead, fresh]).next)
        await #expect(throws: URLError.self) { _ = try await transport.send(post) }
        #expect(dead.retired)
        #expect(fresh.requests == 0)
        #expect(try await transport.send(get).1.statusCode == 200)
    }

    /// Answers (even errors) and being offline say nothing about the connection: it's kept.
    @Test func otherFailuresKeepTheConnection() async throws {
        let connection = Connection { request in
            if request.url?.path == "/offline" { throw URLError(.notConnectedToInternet) }
            return 500
        }
        let connections = Connections([connection])
        let transport = RenewingTransport(makeConnection: connections.next)
        #expect(try await transport.send(get).1.statusCode == 500)
        await #expect(throws: URLError.self) {
            _ = try await transport.send(URLRequest(url: URL(string: "https://api.example.test/offline")!))
        }
        #expect(!connection.retired)
        #expect(connections.made == 1)
    }

    /// A retry that times out too gives up instead of trying forever.
    @Test func retriesOnlyOnce() async {
        let connections = Connections([Connection { _ in throw URLError(.timedOut) }, Connection { _ in throw URLError(.timedOut) },
                                       Connection { _ in 200 }])
        let transport = RenewingTransport(makeConnection: connections.next)
        await #expect(throws: URLError.self) { _ = try await transport.send(get) }
        #expect(connections.made == 3)
    }

    /// Many requests stuck on the same dead connection replace it once, not once each.
    @Test func simultaneousFailuresRenewOnce() async throws {
        let dead = Connection { _ in throw URLError(.timedOut) }
        let fresh = Connection { _ in 200 }
        let connections = Connections([dead, fresh, Connection { _ in 200 }])
        let transport = RenewingTransport(makeConnection: connections.next)
        // Both requests pick the dead connection before either fails.
        let first = transport.connection, second = transport.connection
        #expect(first.transport as? Connection === dead && second.transport as? Connection === dead)
        transport.renew(replacing: first.generation)
        transport.renew(replacing: second.generation)
        #expect(connections.made == 2)
        #expect(transport.connection.transport as? Connection === fresh)
        #expect(dead.retired)
    }
}
