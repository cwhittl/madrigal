import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Availability checks for the on-device model. Safe to call on any OS:
/// FoundationModels needs iOS 26 / macOS 26 on Apple Intelligence hardware,
/// well above the app's deployment target.
enum AppleIntelligence {
    /// The single model the system exposes. Not a real API identifier, just
    /// what gets stored as the conversation's model.
    static let modelID = "apple-on-device"

    /// The model's window is about 4,096 tokens, shared between the prompt
    /// and the reply. Roughly 4 characters per token, this leaves about half
    /// for the answer.
    static let defaultContextCharacterLimit = 8_000

    /// Whether this device and OS can run the on-device model at all,
    /// regardless of whether it's currently turned on or downloaded.
    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return SystemLanguageModel.default.availability != .unavailable(.deviceNotEligible)
        }
        #endif
        return false
    }

    /// Why the model can't be used right now, or nil when it's ready.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This device doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is turned off. Turn it on in Settings under Apple Intelligence & Siri."
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading. Try again later."
            case .unavailable:
                return "The on-device model isn't available right now."
            }
        }
        #endif
        return "Apple Intelligence needs iOS 26 or macOS 26 or later."
    }
}

#if canImport(FoundationModels)

/// Runs chats on Apple's on-device Foundation Models. No key, and no network
/// unless web search is on. Text only: attachments already arrive flattened
/// into message text.
@available(iOS 26, macOS 26, *)
struct AppleIntelligenceProvider: ChatProvider {

    func fetchAvailableModels() async throws -> [String] {
        if let reason = AppleIntelligence.unavailableReason {
            throw ChatProviderError.unavailable(reason: reason)
        }
        return [AppleIntelligence.modelID]
    }

    func streamCompletion(
        messages: [OutgoingMessage],
        model: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        .providerStream(mapError: Self.providerError) { continuation in
            if let reason = AppleIntelligence.unavailableReason {
                throw ChatProviderError.unavailable(reason: reason)
            }

            // "Always" mode was handled before the request, by adding
            // results to the messages.
            var tools: [any Tool] = []
            if let search = options.webSearch, search.mode == .auto {
                tools.append(WebSearchTool(search: search) { continuation.yield($0) })
            }

            let (transcript, prompt) = try Self.transcript(for: messages, tools: tools)
            let session = LanguageModelSession(tools: tools, transcript: transcript)
            let stream = session.streamResponse(
                to: prompt,
                options: FoundationModels.GenerationOptions(
                    temperature: options.temperature,
                    maximumResponseTokens: options.maxTokens
                )
            )

            // Each snapshot is the whole reply so far, not a delta.
            var previous = ""
            for try await snapshot in stream {
                try Task.checkCancellation()
                let text = snapshot.content
                let fragment = text.hasPrefix(previous)
                    ? String(text.dropFirst(previous.count))
                    : text   // Shouldn't happen; never drop text.
                previous = text
                if !fragment.isEmpty {
                    continuation.yield(ChatDelta(textFragment: fragment, isFinal: false))
                }
            }
        }
    }

    /// Folds system messages into the session instructions and replays the
    /// earlier turns, leaving the last user message as the new prompt. Tools
    /// are declared in the instructions, which the session doesn't add for
    /// itself when it starts from a transcript.
    static func transcript(for messages: [OutgoingMessage], tools: [any Tool] = []) throws -> (Transcript, String) {
        let (lastUser, system) = try messages.onDevicePrompt()

        func segments(_ text: String) -> [Transcript.Segment] {
            [.text(Transcript.TextSegment(content: text))]
        }

        var entries: [Transcript.Entry] = []
        let instructions = ([system] + (tools.isEmpty ? [] : [WebSearchConfig.toolGuidance]))
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: segments(instructions),
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
            )))
        }

        for message in messages[..<lastUser] {
            switch message.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(segments: segments(message.content))))
            case .assistant:
                entries.append(.response(Transcript.Response(assetIDs: [], segments: segments(message.content))))
            case .system:
                continue
            }
        }

        return (Transcript(entries: entries), messages[lastUser].content)
    }

    /// Explains the session's errors; others pass through.
    static func providerError(_ error: Error) -> Error {
        guard let error = error as? LanguageModelSession.GenerationError else { return error }
        let message: String
        switch error {
        case .exceededContextWindowSize:
            message = "The conversation is too long for the on-device model. Start a new chat, or lower the context limit in Settings."
        case .guardrailViolation:
            message = "The on-device model's safety guardrails blocked this request."
        case .unsupportedLanguageOrLocale:
            message = "The on-device model doesn't support this language."
        case .assetsUnavailable:
            message = "The on-device model isn't available right now. It may still be downloading."
        case .rateLimited:
            message = "The on-device model is busy. Try again shortly."
        case .concurrentRequests:
            message = "The on-device model is already answering another request."
        case .refusal:
            message = "The on-device model declined to answer."
        default:
            message = error.localizedDescription
        }
        return ChatProviderError.streamError(message: message)
    }
}

/// Lets the on-device model search the web through the provider's search
/// backend. FoundationModels runs the call loop; this only does the search.
@available(iOS 26, macOS 26, *)
struct WebSearchTool: Tool {
    let search: WebSearchConfig
    /// Receives the status and search record deltas for the reply.
    let report: @Sendable (ChatDelta) -> Void

    let name = WebSearchConfig.toolName
    let description = WebSearchConfig.toolDescription

    @Generable
    struct Arguments {
        @Guide(description: "A short web search query, a few keywords.")
        var query: String
    }

    @concurrent
    func call(arguments: Arguments) async throws -> String {
        await search.run(arguments.query, report: report).text
    }
}

#endif
