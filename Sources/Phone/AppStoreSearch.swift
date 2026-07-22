import Foundation

/// Looks up App Store apps by name via the public iTunes Search API — the
/// only way to turn an app name into a bundle ID, since iOS offers no way
/// to enumerate installed apps or observe other apps' notifications.
enum AppStoreSearch {
    enum SearchError: LocalizedError {
        case invalidQuery, invalidResponse, responseTooLarge
        var errorDescription: String? {
            switch self {
            case .invalidQuery: return String(localized: "Enter a shorter app name")
            case .invalidResponse: return String(localized: "The App Store returned an invalid response")
            case .responseTooLarge: return String(localized: "The App Store response was too large")
            }
        }
    }

    static let maximumResponseBytes = 256 * 1024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

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
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 100,
              var components = URLComponents(string: "https://itunes.apple.com/search")
        else { throw SearchError.invalidQuery }
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        guard let url = components.url else { throw SearchError.invalidQuery }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.lowercased() == "application/json" else {
            throw SearchError.invalidResponse
        }
        guard data.count <= maximumResponseBytes else { throw SearchError.responseTooLarge }
        let decoded = try JSONDecoder().decode(Response.self, from: data).results.prefix(20)
        var seen = Set<String>()
        return decoded.compactMap { result in
            guard let bundleID = ProtocolInputValidation.normalizedBundleID(result.bundleId),
                  result.trackName.count <= 200,
                  seen.insert(bundleID.lowercased()).inserted else { return nil }
            return Result(trackName: result.trackName, bundleId: bundleID,
                          artworkUrl60: validatedArtworkURL(result.artworkUrl60))
        }
    }

    private static func validatedArtworkURL(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw), url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com") else { return nil }
        return raw
    }
}
