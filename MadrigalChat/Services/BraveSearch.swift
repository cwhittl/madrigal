import Foundation

/// Brave's Search API: a real web index behind an official JSON API, so it
/// doesn't hit the bot checks that scraping a results page does. Needs the
/// user's own subscription token, from api-dashboard.search.brave.com.
struct BraveSearchClient: WebSearchClient {
    /// Read at search time, so a key saved after the request was set up is
    /// still used, and a missing key surfaces as a failed search.
    let apiKey: @Sendable () -> String?
    var session: URLSession = .shared

    static let missingKeyReason = "No Brave Search API key is saved. Add one in the provider's Web search settings."
    static let rejectedKeyReason = "Brave Search rejected the API key. Check it in the provider's Web search settings."
    static let rateLimitedReason = "Brave Search's rate limit or monthly quota was reached. Try again later, or check your plan."

    /// Keychain account for a provider's Brave key.
    static func keychainKey(for providerKey: String) -> String {
        "\(providerKey).brave"
    }

    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ChatProviderError.unavailable(reason: Self.missingKeyReason)
        }
        let url = try URL.api("https://api.search.brave.com/res/v1/web/search", query: [
            "q": query,
            "count": "\(min(max(limit, 1), 20))"
        ])
        var request = URLRequest(url: url, timeoutInterval: HTTP.searchTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")

        let (data, http) = try await HTTP.data(for: request, session: session)
        let body = HTTP.errorBody(data)
        switch http.statusCode {
        case 200..<300:
            return Array(try Self.decode(data).prefix(limit))
        case 401, 403:
            throw ChatProviderError.unavailable(reason: Self.rejectedKeyReason)
        // Brave answers a bad token with 422 and a SUBSCRIPTION_TOKEN_INVALID code.
        case 422 where body.localizedCaseInsensitiveContains("token"):
            throw ChatProviderError.unavailable(reason: Self.rejectedKeyReason)
        case 429:
            throw ChatProviderError.unavailable(reason: Self.rateLimitedReason)
        default:
            throw ChatProviderError.http(status: http.statusCode, body: body)
        }
    }

    private struct Response: Decodable {
        struct Web: Decodable {
            struct Result: Decodable {
                let title: String?
                let url: String?
                let description: String?
            }
            let results: [Result]?
        }
        let web: Web?
    }

    /// Web results in order, without duplicates. Descriptions mark matches
    /// with `<strong>`, which is stripped.
    static func decode(_ data: Data) throws -> [SearchResult] {
        let response = try HTTP.decode(Response.self, from: data)
        return (response.web?.results ?? []).compactMap { result in
            guard let url = result.url?.nonEmpty else { return nil }
            return SearchResult(
                title: HTMLText.plain(result.title ?? "").nonEmpty ?? url,
                url: url,
                snippet: SearchText.snippet(HTMLText.plain(result.description ?? ""))
            )
        }
        .uniquedByURL()
    }
}
