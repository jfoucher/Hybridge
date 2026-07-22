import Foundation

/// Looks up App Store apps by name via the public iTunes Search API — the
/// only way to turn an app name into a bundle ID, since iOS offers no way
/// to enumerate installed apps or observe other apps' notifications.
enum AppStoreSearch {
    struct Result: Identifiable, Decodable {
        let trackName: String
        let bundleId: String
        let artworkUrl60: String?
        var id: String { bundleId }
    }

    private struct Response: Decodable {
        let results: [Result]
    }

    static func search(_ term: String) async throws -> [Result] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(Response.self, from: data).results
    }
}
