import Foundation
import os

struct ChatDelta: Sendable {
    let textFragment: String
    /// Thinking text from reasoning models, streamed separately from the answer.
    var reasoningFragment: String = ""
    let isFinal: Bool
    /// What the provider is doing instead of writing, such as
    /// "Searching: …". Empty means no change; new text clears it.
    var status: String = ""
    /// A web search the provider ran for this reply, shown as its sources.
    var search: WebSearchRecord? = nil

    static func status(_ text: String) -> ChatDelta {
        ChatDelta(textFragment: "", isFinal: false, status: text)
    }

    static func search(_ record: WebSearchRecord) -> ChatDelta {
        ChatDelta(textFragment: "", isFinal: false, search: record)
    }
}

struct OutgoingMessage: Sendable {
    let role: MessageRole
    let content: String
}

/// Optional sampling parameters. nil fields are omitted from the request
/// entirely, because some models reject an explicit null.
struct GenerationOptions: Sendable {
    var temperature: Double? = nil
    var maxTokens: Int? = nil
    /// Set only for on-device providers with web search turned on.
    var webSearch: WebSearchConfig? = nil
    /// On-device MLX only: what the reply may use once the app is in the
    /// background. A box rather than a value because it can change while
    /// the reply runs: the background task is only submitted once the user
    /// leaves the app. nil means `.pause`. See `BackgroundCompute`.
    var backgroundCompute: BackgroundComputeBox? = nil
    /// On-device MLX only: true for background work, such as chat
    /// summaries, that should stop rather than keep another model from
    /// loading.
    var yieldsToOtherModels = false
}

/// What an on-device MLX reply does once the app is in the background.
enum BackgroundCompute: Sendable, Equatable {
    /// Keeps running on the GPU, through a continued-processing task with
    /// background GPU access (M3 and later iPads).
    case gpu
    /// Pauses, keeping its text, and carries on from there on the GPU once
    /// the app returns (iPhone, and anywhere else without background GPU).
    case pause
}

/// A `BackgroundCompute` that can change while a reply runs, with
/// observers told of each change. Thread-safe.
final class BackgroundComputeBox: Sendable {
    private struct State {
        var value: BackgroundCompute
        var observers: [@Sendable (BackgroundCompute) -> Void] = []
    }
    private let state: OSAllocatedUnfairLock<State>

    init(_ value: BackgroundCompute = .pause) {
        state = OSAllocatedUnfairLock(initialState: State(value: value))
    }

    var value: BackgroundCompute { state.withLock { $0.value } }

    /// Changes the value and tells the observers, outside the lock.
    func set(_ value: BackgroundCompute) {
        let observers: [@Sendable (BackgroundCompute) -> Void]? = state.withLock { state in
            guard state.value != value else { return nil }
            state.value = value
            return state.observers
        }
        for observer in observers ?? [] { observer(value) }
    }

    /// Calls `handler` on every later change. Returns the current value,
    /// read at the same moment, so no change is missed in between.
    @discardableResult
    func observe(_ handler: @escaping @Sendable (BackgroundCompute) -> Void) -> BackgroundCompute {
        state.withLock { state in
            state.observers.append(handler)
            return state.value
        }
    }
}

enum ChatProviderError: LocalizedError {
    case invalidResponse
    case invalidURL(String)
    case http(status: Int, body: String)
    case missingAPIKey
    case missingAccountID          // Cloudflare only, see spec section 6.4
    case decoding(Error)
    /// An error the provider sent inside an otherwise successful stream.
    case streamError(message: String)
    /// The on-device model can't run here, with a reason a person can act on.
    case unavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned a response the app couldn't read."
        case .invalidURL(let url):
            return "\(url) isn't a valid URL."
        case .http(let status, let body):
            switch status {
            case 401, 403:
                return "Authentication failed (\(status)). Check the key or token in Settings."
            case 404:
                return "Endpoint not found (404). Check the base URL, or the account ID for Cloudflare."
            case 429:
                return "Rate limited (429). Try again shortly."
            case 500...599:
                return "The provider had a server error (\(status))."
            default:
                let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "Request failed (\(status))." : "Request failed (\(status)): \(detail)"
            }
        case .missingAPIKey:
            return "No key or token saved for this provider. Check Settings."
        case .missingAccountID:
            return "This Cloudflare provider has no account ID. Check Settings."
        case .decoding(let error):
            return "Couldn't decode the response: \(error.localizedDescription)"
        case .streamError(let message):
            return "The provider reported an error: \(message)"
        case .unavailable(let reason):
            return reason
        }
    }
}

protocol ChatProvider: Sendable {
    /// Best-effort model discovery. Implementations must never make this a
    /// hard gate on using the provider - a failure here falls back to
    /// free-text model entry.
    func fetchAvailableModels() async throws -> [String]

    func streamCompletion(
        messages: [OutgoingMessage],
        model: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ChatDelta, Error>
}

extension AsyncThrowingStream where Element == ChatDelta, Failure == Error {
    /// A provider's reply. `body` runs in a task that's cancelled once the
    /// consumer stops listening, and yields deltas to the continuation.
    /// When it returns, a final empty delta ends the stream, unless `body`
    /// already finished it. A thrown error ends the stream after
    /// `mapError`; cancellation surfaces as `CancellationError`.
    static func providerStream(
        mapError: @escaping @Sendable (Error) -> Error = { $0 },
        _ body: @escaping @Sendable (Continuation) async throws -> Void
    ) -> Self {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.yield(ChatDelta(textFragment: "", isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Array where Element == OutgoingMessage {
    /// What an on-device model replies to: the index of the last user
    /// message, and the non-empty system messages joined. Throws when
    /// there's no user message.
    func onDevicePrompt() throws -> (lastUser: Int, system: String) {
        guard let lastUser = lastIndex(where: { $0.role == .user }) else {
            throw ChatProviderError.streamError(message: "There's no message to reply to.")
        }
        let system = filter { $0.role == .system && !$0.content.isEmpty }
            .map(\.content)
            .joined(separator: "\n\n")
        return (lastUser, system)
    }
}
