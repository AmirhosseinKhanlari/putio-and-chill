import AMDBCore
import Foundation
import Testing
@testable import AMDBKit

private final class SequenceTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var polls = 0
    private(set) var requests: [URL] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body: String = lock.withLock {
            requests.append(url)
            if url.path.hasSuffix("/oauth2/oob/code") {
                return #"{"code":"RWIFUC","qr_code_url":"https://api.put.io/v2/oauth2/oob/qr/RWIFUC","status":"OK"}"#
            }
            polls += 1
            return polls < 3 ? #"{"oauth_token":null,"status":"OK"}"# : #"{"oauth_token":"TOKEN","status":"OK"}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Suite struct DeviceSignInTests {
    @Test func showsCodeThenSignsInWhenLinked() async throws {
        let transport = SequenceTransport()
        var token: String?
        let signIn = DeviceSignIn(appID: "9877", transport: transport, pollInterval: .milliseconds(10)) { token = $0 }
        signIn.start()
        try await waitUntil { if case .waiting = signIn.phase { return true }; return signIn.phase == .signedIn }
        try await waitUntil { signIn.phase == .signedIn }
        #expect(token == "TOKEN")
        #expect(transport.requests.first?.query() == "app_id=9877")
        #expect(transport.requests.last?.path == "/v2/oauth2/oob/code/RWIFUC")
    }

    @Test func parsesDeviceCode() async throws {
        let code = try await PutioClient.requestDeviceCode(appID: "9877", transport: SequenceTransport())
        #expect(code == PutioDeviceCode(code: "RWIFUC", qrCodeURL: URL(string: "https://api.put.io/v2/oauth2/oob/qr/RWIFUC")))
    }
}
