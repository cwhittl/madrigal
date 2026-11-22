import Foundation

/// The "fetch, then 2xx or throw" steps every plain (non-streaming) request
/// shares. Callers that treat some statuses specially switch on
/// `statusCode` first, then call `ensureSuccess` for the rest.
enum HTTP {
    /// Shared, since a decoder is costly to create and safe to reuse.
    static let decoder = JSONDecoder()

    /// How much of an error body is kept to show what went wrong.
    static let errorBodyLimit = 500

    /// Chat requests can sit silent for minutes while a reasoning model
    /// thinks, well past URLSession's 60-second default.
    static let chatTimeout: TimeInterval = 300

    /// Timeouts for requests a reply waits on: searches, the pages behind
    /// their results, and weather lookups.
    static let searchTimeout: TimeInterval = 15
    static let pageTimeout: TimeInterval = 8
    static let weatherTimeout: TimeInterval = 10

    /// A desktop Safari user agent. Some sites serve an empty shell, an
    /// error, or a bot check to clients they don't recognize.
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    /// Decodes `data`, throwing `ChatProviderError.decoding` on failure.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ChatProviderError.decoding(error)
        }
    }

    /// The body and response. Throws for transport failures and non-HTTP
    /// responses, but not for any status code.
    static func data(for request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatProviderError.invalidResponse }
        return (data, http)
    }

    /// The body of a 2xx response; anything else throws.
    static func successfulData(for request: URLRequest, session: URLSession) async throws -> Data {
        let (data, http) = try await Self.data(for: request, session: session)
        try ensureSuccess(http, data: data)
        return data
    }

    /// Throws `ChatProviderError.http` for a non-2xx status, with `body`
    /// turning the response into its message.
    static func ensureSuccess(_ http: HTTPURLResponse, data: Data, body: (Data) -> String = HTTP.errorBody) throws {
        guard http.isSuccess else {
            throw ChatProviderError.http(status: http.statusCode, body: body(data))
        }
    }

    /// The start of a response body, enough to show what went wrong.
    static func errorBody(_ data: Data) -> String {
        String(decoding: data.prefix(errorBodyLimit), as: UTF8.self)
    }
}

extension HTTPURLResponse {
    var isSuccess: Bool { (200..<300).contains(statusCode) }
}

extension URL {
    /// `string` with `query` added in order. Throws `invalidURL` when they
    /// don't make a URL, such as a host built from bad input.
    static func api(_ string: String, query: KeyValuePairs<String, String> = [:]) throws -> URL {
        guard var components = URLComponents(string: string) else { throw ChatProviderError.invalidURL(string) }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw ChatProviderError.invalidURL(string) }
        return url
    }
}

extension Locale {
    /// The device's language as a two- or three-letter code, for APIs that
    /// take one. English when there isn't a usable one.
    static var apiLanguageCode: String {
        let code = current.language.languageCode?.identifier.lowercased() ?? ""
        let valid = (2...3).contains(code.count) && code.allSatisfy { $0.isASCII && $0.isLetter }
        return valid ? code : "en"
    }
}
