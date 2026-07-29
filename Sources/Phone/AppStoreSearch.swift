import Foundation
import os.log

/// Looks up App Store apps by name via the public iTunes Search API — the
/// only way to turn an app name into a bundle ID, since iOS offers no way
/// to enumerate installed apps or observe other apps' notifications.
enum AppStoreSearch {
    enum SearchError: LocalizedError, Equatable {
        case invalidQuery
        case httpStatus(Int)
        case unexpectedContentType(String)
        case responseTooLarge(Int)
        case decoding(String)
        var errorDescription: String? {
            switch self {
            case .invalidQuery:
                return String(localized: "Enter a shorter app name")
            case .httpStatus(let code):
                return String(localized: "The App Store returned an error (HTTP \(code))")
            case .unexpectedContentType(let type):
                return String(localized: "The App Store returned an unexpected content type (\(type))")
            case .responseTooLarge(let bytes):
                return String(localized: "The App Store response was too large (\(bytes) bytes)")
            case .decoding:
                return String(localized: "The App Store returned an invalid response")
            }
        }
    }

    private static let logger = Logger(subsystem: "eu.sixpixels.hybridge", category: "appsearch")

    /// A 20-result `entity=software` response is ~130–190 KB of metadata in
    /// practice; the cap only exists to bound memory on a pathological reply.
    static let maximumResponseBytes = 2 * 1024 * 1024

    /// The iTunes Search API answers with `text/javascript; charset=utf-8`
    /// (a JSONP-era leftover), *not* `application/json` — insisting on the
    /// latter rejected every single real response.
    static let acceptedContentTypes: Set<String> = [
        "application/json", "text/javascript", "text/json", "application/javascript",
    ]

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

    /// One malformed entry must not fail the whole search: each element is
    /// decoded through a wrapper that never throws, and the misses are dropped.
    private struct Failable: Decodable {
        let value: Result?
        init(from decoder: Decoder) throws { value = try? Result(from: decoder) }
    }

    private struct Response: Decodable {
        let results: [Failable]
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
        logger.debug("search request \(url.absoluteString, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            logger.error("search transport failure: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        return try results(from: data, status: (response as? HTTPURLResponse)?.statusCode,
                           contentType: (response as? HTTPURLResponse)?.mimeType)
    }

    /// Response validation + decoding, split out from the transport so it is
    /// unit-testable without hitting the network.
    static func results(from data: Data, status: Int?, contentType: String?) throws -> [Result] {
        let mime = contentType?.lowercased() ?? "(none)"
        logger.debug(
            "search response status=\(status ?? -1, privacy: .public) type=\(mime, privacy: .public) bytes=\(data.count, privacy: .public)")

        guard let status, status == 200 else { throw SearchError.httpStatus(status ?? -1) }
        guard acceptedContentTypes.contains(mime) else {
            logger.error("search rejected content type \(mime, privacy: .public)")
            throw SearchError.unexpectedContentType(mime)
        }
        guard data.count <= maximumResponseBytes else {
            logger.error("search response too large: \(data.count, privacy: .public) bytes")
            throw SearchError.responseTooLarge(data.count)
        }

        let payload: Response
        do {
            payload = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            logger.error("search decode failure: \(String(describing: error), privacy: .public)")
            throw SearchError.decoding(String(describing: error))
        }

        var seen = Set<String>()
        let results: [Result] = payload.results.prefix(20).compactMap { entry in
            guard let result = entry.value,
                  let bundleID = ProtocolInputValidation.normalizedBundleID(result.bundleId),
                  result.trackName.count <= 200,
                  seen.insert(bundleID.lowercased()).inserted else { return nil }
            return Result(trackName: result.trackName, bundleId: bundleID,
                          artworkUrl60: validatedArtworkURL(result.artworkUrl60))
        }
        logger.debug(
            "search returned \(payload.results.count, privacy: .public) raw, \(results.count, privacy: .public) usable results")
        return results
    }

    private static func validatedArtworkURL(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw), url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com") else { return nil }
        return raw
    }
}
