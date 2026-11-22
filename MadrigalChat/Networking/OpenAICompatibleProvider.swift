import Foundation

/// Talks to any endpoint that speaks OpenAI's `/chat/completions` and
/// (optionally) `/models`. Covers OpenAI, OpenRouter, Groq, Together,
/// LM Studio, llama.cpp servers, AI Gateway URLs, and so on.
///
/// `CloudflareWorkersAIProvider` wraps one of these for the chat and
/// streaming path, adding its own URL scheme and model discovery.
struct OpenAICompatibleProvider: ChatProvider {

    let baseURL: String
    let apiKey: String
    let cfAccessClientID: String
    let cfAccessClientSecret: String
    let session: URLSession
    /// The base URL's host, for the vendor quirks below.
    private let host: String?

    init(
        baseURL: String,
        apiKey: String,
        cfAccessClientID: String = "",
        cfAccessClientSecret: String = "",
        session: URLSession = .shared
    ) {
        // Trailing slashes turn into "//chat/completions" on some proxies.
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingSuffix("/")
        self.host = URL(string: self.baseURL)?.host
        self.apiKey = apiKey
        self.cfAccessClientID = cfAccessClientID
        self.cfAccessClientSecret = cfAccessClientSecret
        self.session = session
    }

    // MARK: - Requests

    func chatCompletionsURL() throws -> URL {
        try url(path: "/chat/completions")
    }

    func modelsURL() throws -> URL {
        // Anthropic's model list pages at 20 by default; ask for all of them.
        try url(path: isAnthropic ? "/models?limit=1000" : "/models")
    }

    /// Anthropic's chat endpoint takes the bearer token like everyone else,
    /// but `/models` is its native API, which wants `x-api-key` and a
    /// version header instead.
    var isAnthropic: Bool { host == "api.anthropic.com" }

    func url(path: String) throws -> URL {
        guard let url = URL(string: baseURL + path), url.scheme != nil, url.host != nil else {
            throw ChatProviderError.invalidURL(baseURL + path)
        }
        return url
    }

    func authorize(_ request: inout URLRequest) {
        // Optional: some endpoints are gated only by Cloudflare Access (or
        // nothing at all) and don't expect a bearer token.
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if isAnthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
        }
        // Cloudflare Access requires these two headers on every request.
        if !cfAccessClientID.isEmpty {
            request.setValue(cfAccessClientID, forHTTPHeaderField: "CF-Access-Client-Id")
        }
        if !cfAccessClientSecret.isEmpty {
            request.setValue(cfAccessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
    }

    // MARK: - Models

    func fetchAvailableModels() async throws -> [String] {
        var request = URLRequest(url: try modelsURL())
        request.httpMethod = "GET"
        authorize(&request)

        let (data, http) = try await HTTP.data(for: request, session: session)
        try HTTP.ensureSuccess(http, data: data, body: Self.humanReadableError)

        return try Self.decodeModelIDs(from: data)
    }

    /// Most servers wrap the list as `{"data":[{"id":...}]}`; Together
    /// returns the bare array. Gemini prefixes IDs with `models/`, which its
    /// chat endpoint doesn't need.
    static func decodeModelIDs(from data: Data) throws -> [String] {
        struct Model: Decodable { let id: String }
        struct ModelList: Decodable { let data: [Model] }

        let models = try (try? HTTP.decoder.decode(ModelList.self, from: data))?.data
            ?? HTTP.decode([Model].self, from: data)
        return models
            .map { $0.id.hasPrefix("models/") ? String($0.id.dropFirst("models/".count)) : $0.id }
            .sorted()
    }

    // MARK: - Chat

    /// Deliberately minimal: Workers AI (which uses this) rejects or
    /// ignores extras like top_p depending on the model.
    func requestBody(messages: [OutgoingMessage], model: String, options: GenerationOptions) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: model,
            messages: messages.map { .init(role: $0.role, content: $0.content) },
            temperature: options.temperature,
            // OpenAI's reasoning models reject max_tokens outright.
            maxTokens: isOpenAI ? nil : options.maxTokens,
            maxCompletionTokens: isOpenAI ? options.maxTokens : nil
        )
    }

    var isOpenAI: Bool { host == "api.openai.com" }

    func streamCompletion(
        messages: [OutgoingMessage],
        model: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        .providerStream { continuation in
            var request = URLRequest(url: try chatCompletionsURL())
            request.httpMethod = "POST"
            request.timeoutInterval = HTTP.chatTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            authorize(&request)
            request.httpBody = try JSONEncoder().encode(
                requestBody(messages: messages, model: model, options: options)
            )

            let (bytes, response) = try await session.bytes(for: request)

            if let http = response as? HTTPURLResponse, !http.isSuccess {
                // Error bodies are not SSE - drain and surface them.
                var raw = Data()
                for try await byte in bytes {
                    raw.append(byte)
                    if raw.count > 32_768 { break }
                }
                throw ChatProviderError.http(status: http.statusCode, body: Self.humanReadableError(from: raw))
            }

            // Returning ends the stream as complete, including when it
            // closes without a [DONE].
            for try await line in bytes.lines {
                try Task.checkCancellation()

                switch SSEParser.event(forLine: line) {
                case .ignored:
                    continue
                case .done:
                    return
                case .chunk(let json):
                    let (text, reasoning, finished) = try SSEParser.decodeChunk(json)
                    if !text.isEmpty || !reasoning.isEmpty || finished {
                        // Some endpoints send finish_reason and then close
                        // without a [DONE] sentinel.
                        continuation.yield(ChatDelta(textFragment: text, reasoningFragment: reasoning, isFinal: finished))
                    }
                    if finished { return }
                }
            }
        }
    }

    // MARK: - Shared helpers

    /// Pulls a message out of either OpenAI's `{"error":{"message":...}}` or
    /// Cloudflare's `{"success":false,"errors":[{"message":...}]}` envelope,
    /// falling back to the raw body.
    static func humanReadableError(from data: Data) -> String {
        guard !data.isEmpty else { return "" }

        if let envelope = try? HTTP.decoder.decode(ErrorEnvelope.self, from: data) {
            switch envelope.error {
            case .detail(let detail?), .message(let detail?):
                return detail
            default:
                break
            }
            let messages = (envelope.errors ?? []).compactMap(\.message)
            if !messages.isEmpty { return messages.joined(separator: "; ") }
            if let message = envelope.message { return message }
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        return text.truncated(to: HTTP.errorBodyLimit)
    }
}

/// The body of a `/chat/completions` request. Optional fields are left out
/// when nil, because some models reject an explicit null.
struct ChatCompletionRequest: Encodable, Equatable {
    struct Message: Encodable, Equatable {
        let role: MessageRole
        let content: String
    }

    let model: String
    let messages: [Message]
    var stream = true
    var temperature: Double?
    var maxTokens: Int?
    var maxCompletionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }
}

/// Error bodies, in any of the shapes providers use: OpenAI's
/// `{"error":{"message":...}}`, a bare `{"error":"..."}`, Cloudflare's
/// `{"errors":[{"message":...}]}`, or a top-level `message`.
private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String? }

    enum ErrorField: Decodable {
        case detail(String?)
        case message(String?)
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .message(text)
            } else if let detail = try? container.decode(Detail.self) {
                self = .detail(detail.message)
            } else {
                self = .other
            }
        }
    }

    let error: ErrorField?
    let errors: [Detail]?
    let message: String?

    enum CodingKeys: CodingKey { case error, errors, message }

    // Lenient: a field of an unexpected shape is skipped, not fatal.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try? container.decodeIfPresent(ErrorField.self, forKey: .error)
        errors = try? container.decodeIfPresent([Detail].self, forKey: .errors)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
    }
}
