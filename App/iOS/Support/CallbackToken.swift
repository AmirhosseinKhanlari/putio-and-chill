import Foundation

enum CallbackToken {
    /// Reads `name` from a URL's fragment (`#name=…`) or query (`?name=…`).
    static func value(named name: String, in url: URL) -> String? {
        for part in [url.fragment, URLComponents(url: url, resolvingAgainstBaseURL: false)?.query] {
            guard let part else { continue }
            var components = URLComponents()
            components.query = part
            if let value = components.queryItems?.first(where: { $0.name == name })?.value, !value.isEmpty { return value }
        }
        return nil
    }
}
