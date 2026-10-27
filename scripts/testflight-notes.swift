// Puts a build's "What to Test" (the changelog testers see in TestFlight) on every platform's copy of that build.
// Waits until App Store Connect has processed the upload, then sets the en-US text.
//
//   swift scripts/testflight-notes.swift <bundle id> <build number> <notes file> [copies]
//
// `copies` is how many platforms the build was uploaded for (2 for iPhone/iPad and Apple TV, the default): each copy
// shows up in App Store Connect separately, minutes apart, so it waits for all of them.
// Signs in with the App Store Connect API key in the repo root (AuthKey_62289X2HZR.p8, gitignored); ASC_KEY_PATH,
// ASC_KEY_ID and ASC_ISSUER_ID override it.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 || args.count == 5, let copies = Int(args.count == 5 ? args[4] : "2"), copies > 0 else {
    print("usage: swift scripts/testflight-notes.swift <bundle id> <build number> <notes file> [copies]")
    exit(2)
}
let (bundleID, build) = (args[1], args[2])
let notes = try String(contentsOfFile: args[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard !notes.isEmpty, notes.count <= 4000 else { print("notes must be 1–4000 characters"); exit(2) }

let env = ProcessInfo.processInfo.environment
let keyID = env["ASC_KEY_ID"] ?? "62289X2HZR"
let issuer = env["ASC_ISSUER_ID"] ?? "f5376a4b-df4e-4795-b65c-d9aae396b825"
let keyPath = env["ASC_KEY_PATH"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "AuthKey_\(keyID).p8").path

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// A 15-minute API token.
func token() throws -> String {
    let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: keyPath, encoding: .utf8))
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let claims = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"])
    let input = "\(base64URL(header)).\(base64URL(claims))"
    return "\(input).\(base64URL(try key.signature(for: Data(input.utf8)).rawRepresentation))"
}

func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com\(path)")!)
    request.httpMethod = method
    request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw NSError(domain: "ASC", code: status, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path) → \(status): \(String(decoding: data, as: UTF8.self))"])
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func items(_ json: [String: Any]) -> [[String: Any]] { json["data"] as? [[String: Any]] ?? [] }
func attributes(_ item: [String: Any]) -> [String: Any] { item["attributes"] as? [String: Any] ?? [:] }

guard let app = items(try await call("GET", "/v1/apps?filter%5BbundleId%5D=\(bundleID)")).first?["id"] as? String else {
    print("no app with bundle id \(bundleID)"); exit(1)
}

// Every platform's copy of the build, once all `copies` are processed (up to 30 minutes).
var builds: [[String: Any]] = []
for attempt in 0..<60 {
    builds = items(try await call("GET", "/v1/builds?filter%5Bapp%5D=\(app)&filter%5Bversion%5D=\(build)&include=preReleaseVersion&limit=10"))
    let states = builds.map { attributes($0)["processingState"] as? String ?? "?" }
    if states.count >= copies, states.allSatisfy({ $0 == "VALID" }) { break }
    if states.contains(where: { $0 == "FAILED" || $0 == "INVALID" }) { print("build \(build) failed processing: \(states)"); exit(1) }
    if attempt == 59 { print("build \(build) still not processed: \(states)"); exit(1) }
    print("waiting for build \(build): \(states.count) of \(copies) copies listed (\(states.joined(separator: ", ")))")
    try await Task.sleep(for: .seconds(30))
}

for item in builds {
    let id = item["id"] as! String
    let existing = items(try await call("GET", "/v1/builds/\(id)/betaBuildLocalizations"))
        .first { attributes($0)["locale"] as? String == "en-US" }
    if let localization = existing?["id"] as? String {
        _ = try await call("PATCH", "/v1/betaBuildLocalizations/\(localization)", ["data": [
            "type": "betaBuildLocalizations", "id": localization, "attributes": ["whatsNew": notes]]])
    } else {
        _ = try await call("POST", "/v1/betaBuildLocalizations", ["data": [
            "type": "betaBuildLocalizations", "attributes": ["locale": "en-US", "whatsNew": notes],
            "relationships": ["build": ["data": ["type": "builds", "id": id]]]]])
    }
    print("What to Test set on build \(build) (\(id))")
}
