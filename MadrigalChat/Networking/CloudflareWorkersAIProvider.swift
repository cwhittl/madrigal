import Foundation

/// Cloudflare Workers AI.
///
/// The chat wire format is OpenAI-compatible, so chat and streaming go
/// through a wrapped `OpenAICompatibleProvider`. Three things differ, and
/// only these three are handled here (see spec section 6.4):
///
///  1. The base URL embeds the account ID.
///  2. Model discovery is Cloudflare's own `/ai/models/search`, not `/v1/models`.
///  3. Model IDs are path-shaped `@cf/...` strings, and only a conservative
///     set of request parameters is safe to send.
struct CloudflareWorkersAIProvider: ChatProvider {

    let accountID: String
    /// Chat, streaming, and request authorization.
    let chat: OpenAICompatibleProvider

    init(
        accountID: String,
        apiToken: String,
        cfAccessClientID: String = "",
        cfAccessClientSecret: String = "",
        session: URLSession = .shared
    ) {
        self.accountID = Self.normalizedAccountID(accountID)
        self.chat = OpenAICompatibleProvider(
            baseURL: Self.baseURL(forAccount: accountID),
            apiKey: apiToken,
            cfAccessClientID: cfAccessClientID,
            cfAccessClientSecret: cfAccessClientSecret,
            session: session
        )
    }

    // MARK: - URLs

    static let apiRoot = "https://api.cloudflare.com/client/v4"

    /// Trimmed and lowercased, the way the API's URLs use it.
    static func normalizedAccountID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func baseURL(forAccount accountID: String) -> String {
        "\(apiRoot)/accounts/\(normalizedAccountID(accountID))/ai/v1"
    }

    /// Account IDs are 32 lowercase hex characters. Checking this in the UI
    /// turns a confusing 404 into an inline hint.
    static func isValidAccountID(_ id: String) -> Bool {
        let normalized = normalizedAccountID(id)
        guard normalized.count == 32 else { return false }
        return normalized.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func modelSearchURL() throws -> URL {
        let string = "\(Self.apiRoot)/accounts/\(accountID)/ai/models/search"
        guard var components = URLComponents(string: string) else {
            throw ChatProviderError.invalidURL(string)
        }
        components.queryItems = [
            URLQueryItem(name: "task", value: "Text Generation"),
            URLQueryItem(name: "per_page", value: "200")
        ]
        guard let url = components.url else { throw ChatProviderError.invalidURL(string) }
        return url
    }

    // MARK: - Model discovery

    /// Cloudflare's envelope:
    /// `{"success":true,"result":[{"id":"...","name":"@cf/meta/llama-3.1-8b-instruct",
    ///   "task":{"name":"Text Generation"}}]}`
    private struct ModelSearchResponse: Decodable {
        struct Model: Decodable {
            struct Task: Decodable { let name: String? }
            let id: String?
            let name: String?
            let task: Task?
        }
        let success: Bool?
        let result: [Model]?
    }

    func streamCompletion(
        messages: [OutgoingMessage],
        model: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        chat.streamCompletion(messages: messages, model: model, options: options)
    }

    func fetchAvailableModels() async throws -> [String] {
        var request = URLRequest(url: try modelSearchURL())
        request.httpMethod = "GET"
        chat.authorize(&request)

        let (data, http) = try await HTTP.data(for: request, session: chat.session)
        try HTTP.ensureSuccess(http, data: data, body: OpenAICompatibleProvider.humanReadableError)

        let decoded = try HTTP.decode(ModelSearchResponse.self, from: data)

        let ids = (decoded.result ?? [])
            .filter { model in
                // The `task` filter is applied server-side, but not every
                // deployment honors the query param, so filter again here
                // when the field is present.
                guard let taskName = model.task?.name else { return true }
                return taskName.caseInsensitiveCompare("Text Generation") == .orderedSame
            }
            .compactMap { $0.name ?? $0.id }
            .filter { !$0.isEmpty }

        // Discovery is a convenience, never a gate. An empty or unrecognized
        // result still leaves the user with something to pick from, and the
        // model field stays free-text either way.
        return ids.isEmpty ? Self.fallbackModelIDs : Array(Set(ids)).sorted()
    }

    /// Used when the search endpoint is unreachable or the token lacks the
    /// Workers AI Read scope. Deliberately short: these are starting points,
    /// not a catalog. Cloudflare's model list moves faster than this app ships.
    static let fallbackModelIDs: [String] = [
        "@cf/meta/llama-3.1-8b-instruct",
        "@cf/meta/llama-3.1-70b-instruct",
        "@cf/meta/llama-3.2-3b-instruct",
        "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
        "@cf/mistral/mistral-7b-instruct-v0.2",
        "@cf/qwen/qwen1.5-14b-chat-awq",
        "@cf/google/gemma-7b-it"
    ]
}
