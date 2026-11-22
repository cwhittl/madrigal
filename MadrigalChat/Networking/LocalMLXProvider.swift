import Foundation
#if !targetEnvironment(simulator) && arch(arm64)
import Metal
import MLX
import MLXLMCommon
#endif

/// Availability and shared logic for open-weight models run with MLX. Safe
/// to use on any device: MLX needs Metal on Apple silicon, so the Simulator
/// and Intel Macs report it as unsupported.
enum LocalMLX {
    /// Small models handle a few thousand tokens comfortably on a phone.
    /// About 4,000 tokens of context leaves room for the reply.
    static let defaultContextCharacterLimit = 16_000

    /// Generation stops here when the provider has no max tokens set, so a
    /// model stuck in a loop can't run forever.
    static let defaultMaxTokens = 4_096

    /// Why on-device models can't run here, or nil when they can.
    static var unavailableReason: String? {
        #if targetEnvironment(simulator)
        return "On-device models need a real iPhone, iPad, or Mac. They can't run in the Simulator."
        #elseif !arch(arm64)
        return "On-device models need a Mac with Apple silicon."
        #else
        return MTLCreateSystemDefaultDevice() == nil ? "This device has no supported GPU for on-device models." : nil
        #endif
    }

    static func notDownloadedMessage(for model: String) -> String {
        "\(LocalModelInfo.displayName(for: model)) isn't downloaded on this device. Download it in Settings."
    }

    /// Shapes a request for chat templates, which are much stricter than
    /// hosted APIs: one leading system message, then strictly alternating
    /// turns that end with the user. Anything after the last user message
    /// is dropped, the same as Apple Intelligence.
    static func chatTurns(for messages: [OutgoingMessage]) throws -> [OutgoingMessage] {
        let (lastUser, system) = try messages.onDevicePrompt()

        var turns: [OutgoingMessage] = []
        if !system.isEmpty {
            turns.append(OutgoingMessage(role: .system, content: system))
        }

        for message in messages[...lastUser] where message.role != .system && !message.content.isEmpty {
            guard message.role == .user || message.role == .assistant else { continue }
            if let last = turns.last, last.role == message.role {
                turns[turns.count - 1] = OutgoingMessage(role: last.role, content: last.content + "\n\n" + message.content)
            } else {
                turns.append(message)
            }
        }

        // Most templates need the conversation to open with the user.
        if let first = turns.firstIndex(where: { $0.role != .system }), turns[first].role == .assistant {
            turns.remove(at: first)
        }
        return turns
    }

    // MARK: - Web search

    /// Search rounds before the model must answer with what it has.
    static let maxSearchRounds = 3

    /// The `web_search` tool in the JSON-schema shape chat templates expect.
    static var webSearchToolSpec: [String: any Sendable] {
        [
            "type": "function",
            "function": [
                "name": WebSearchConfig.toolName,
                "description": WebSearchConfig.toolDescription,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": WebSearchConfig.queryDescription] as [String: any Sendable]
                    ] as [String: any Sendable],
                    "required": ["query"]
                ] as [String: any Sendable]
            ] as [String: any Sendable]
        ]
    }

    /// A chat turn, including the tool turns a search round adds.
    enum Turn: Sendable {
        case message(OutgoingMessage)
        /// The model's text for the round, without thinking, and its calls.
        case toolCalls(text: String, calls: [ToolRequest])
        case toolResult(id: String?, name: String, content: String)
    }

    struct ToolRequest: Sendable, Equatable {
        var id: String?
        var name: String
        /// nil when the arguments had no usable query.
        var query: String?
    }

    enum GenerationEvent: Sendable {
        case text(String)
        case toolCall(ToolRequest)
        /// What the generation is doing instead of writing, such as
        /// waiting for the app to return.
        case status(String)
    }

    /// Runs one generation over `history`, with the search tool if
    /// `allowTools`, reporting what it produces to `onEvent`.
    typealias Generate = (_ history: [Turn], _ allowTools: Bool, _ onEvent: (GenerationEvent) -> Void) async throws -> Void

    /// The model's chat template couldn't render the tool definitions.
    /// Only ever thrown out of `generateWithSearch` from the first round,
    /// before anything has been streamed, so falling back can't repeat text.
    struct ToolsUnsupported: Error {}

    /// Generates, runs any searches the model asks for, and generates
    /// again, up to `maxSearchRounds` times. Text streams out as it arrives;
    /// the last round has no tools, so the model has to answer.
    static func generateWithSearch(
        turns: [OutgoingMessage],
        search: WebSearchConfig,
        emit: @escaping @Sendable (ChatDelta) -> Void,
        generate: Generate
    ) async throws {
        var history = turns.map(Turn.message)
        for round in 0...maxSearchRounds {
            let allowTools = round < maxSearchRounds
            var text = ""
            var calls: [ToolRequest] = []
            let onEvent: (GenerationEvent) -> Void = { event in
                switch event {
                case .text(let fragment):
                    text += fragment
                    emit(ChatDelta(textFragment: fragment, isFinal: false))
                case .toolCall(let call):
                    calls.append(call)
                case .status(let status):
                    emit(.status(status))
                }
            }
            do {
                try await generate(history, allowTools, onEvent)
            } catch is ToolsUnsupported where round > 0 {
                // The template took the tools but not this round's tool
                // turns. Answer from what's here: starting over would
                // repeat what's already been streamed.
                try await generate(history, false, onEvent)
                return
            }
            guard allowTools, !calls.isEmpty else { return }
            try Task.checkCancellation()

            let answer = InlineThinking.split(text).answer
            history.append(.toolCalls(text: answer, calls: calls))
            for call in calls {
                let content: String
                if call.name == WebSearchConfig.toolName, let query = call.query, !query.isEmpty {
                    content = await search.run(query, report: emit).text
                } else {
                    content = "There's no tool called \(call.name) with those arguments. Only web_search, with a query, is available."
                }
                history.append(.toolResult(id: call.id, name: call.name, content: content))
            }
            try Task.checkCancellation()
            // Keeps the next round's answer from running into this round's.
            if !answer.isEmpty { emit(ChatDelta(textFragment: "\n\n", isFinal: false)) }
        }
    }
}

#if !targetEnvironment(simulator) && arch(arm64)

/// Runs downloaded open-weight models on this device with MLX. No key, and
/// no network unless web search is on. Reasoning models' inline <think> tags pass through as text;
/// `StreamAccumulator` splits them out like any other stream.
struct LocalMLXProvider: ChatProvider {
    var runtime: LocalModelRuntime = .shared

    /// The models downloaded on this device, not every device on the account.
    func fetchAvailableModels() async throws -> [String] {
        await LocalModelStore.shared.installedIDs
    }

    func streamCompletion(
        messages: [OutgoingMessage],
        model: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        .providerStream { continuation in
            let turns = try LocalMLX.chatTurns(for: messages)
            guard let reference = await LocalModelStore.shared.loadReference(for: model) else {
                throw ChatProviderError.unavailable(reason: LocalMLX.notDownloadedMessage(for: model))
            }

            // Finishing the stream also cancels this task through
            // onTermination, which ends MLX's generation loop.
            let control = GenerationControl { reason in
                continuation.finish(throwing: ChatProviderError.unavailable(reason: reason))
            }
            let generation = await runtime.beginGeneration(
                backgroundCompute: options.backgroundCompute,
                yieldsToOtherModels: options.yieldsToOtherModels,
                control: control
            )
            do {
                try await respond(
                    to: messages, turns: turns, model: reference, generation: generation,
                    control: control, options: options, continuation: continuation
                )
            } catch {
                await runtime.endGeneration(generation)
                throw error
            }
            await runtime.endGeneration(generation)
        }
    }

    /// Loads the model and streams the reply, searching first or along
    /// the way as the provider's web search settings say.
    private func respond(
        to messages: [OutgoingMessage],
        turns: [OutgoingMessage],
        model reference: LocalModelReference,
        generation: UUID,
        control: GenerationControl,
        options: GenerationOptions,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws {
        let container = try await runtime.container(for: reference, generation: generation)
        try Task.checkCancellation()

        var parameters = GenerateParameters(maxTokens: options.maxTokens ?? LocalMLX.defaultMaxTokens)
        if let temperature = options.temperature {
            parameters.temperature = Float(temperature)
        }

        let generate: LocalMLX.Generate = { history, allowTools, onEvent in
            try await Self.generate(
                history: history,
                tools: allowTools ? [LocalMLX.webSearchToolSpec] : nil,
                container: container,
                parameters: parameters,
                control: control,
                onEvent: onEvent
            )
        }

        // "Always" mode was handled before the request, by adding results
        // to the messages.
        guard let search = options.webSearch, search.mode == .auto else {
            try await generate(turns.map(LocalMLX.Turn.message), false) { Self.yieldPlain($0, to: continuation) }
            return
        }
        do {
            try await LocalMLX.generateWithSearch(
                turns: turns, search: search,
                emit: { continuation.yield($0) }, generate: generate
            )
        } catch is LocalMLX.ToolsUnsupported {
            // This model's template can't take tools: search up front
            // instead, as "always" mode does.
            let searched = await search.injectingResults(into: messages) { continuation.yield($0) }
            try Task.checkCancellation()
            try await generate(try LocalMLX.chatTurns(for: searched.messages).map(LocalMLX.Turn.message), false) {
                Self.yieldPlain($0, to: continuation)
            }
        }
    }

    /// Text and status from a generation without tools.
    private static func yieldPlain(
        _ event: LocalMLX.GenerationEvent,
        to continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) {
        switch event {
        case .text(let text): continuation.yield(ChatDelta(textFragment: text, isFinal: false))
        case .status(let status): continuation.yield(.status(status))
        case .toolCall: break
        }
    }

    static let pausedStatus = "Paused — continues when you return"
    static let resumingStatus = "Resuming…"

    /// Generates one reply (one round, with web search). If the app goes to
    /// the background without background GPU access, `GenerationLifecycle`
    /// pauses the reply: the run is cancelled, its GPU work finishes, and
    /// the next run waits in `startRun` until the app returns, then carries
    /// on from the text so far. The caller sees a status line meanwhile.
    private static func generate(
        history: [LocalMLX.Turn],
        tools: [[String: any Sendable]]?,
        container: ModelContainer,
        parameters: GenerateParameters,
        control: GenerationControl,
        onEvent: (LocalMLX.GenerationEvent) -> Void
    ) async throws {
        let maxTokens = parameters.maxTokens ?? LocalMLX.defaultMaxTokens
        // Everything written so far, thinking included, to resume from.
        var generatedText = ""
        while true {
            let waited = control.isPaused
            if waited { onEvent(.status(pausedStatus)) }
            try await control.startRun()
            if waited { onEvent(.status(resumingStatus)) }
            let partialText = generatedText
            let stopReason: GenerateStopReason?
            do {
                // MLX runs in a child task. Its events come back through a
                // stream, since `onEvent` isn't Sendable.
                let (events, sink) = AsyncStream<LocalMLX.GenerationEvent>.makeStream()
                async let outcome: GenerateStopReason? = {
                    defer { sink.finish() }
                    // MLX's default error handler calls fatalError. This
                    // turns its errors into throws instead, including those
                    // from MLX's generation task, which inherits the handler.
                    // `run` checks the box as text arrives, so nothing
                    // generated after a failed eval is kept.
                    return try await withError { errors in
                        try await run(
                            history: history, tools: tools, container: container,
                            parameters: parameters, maxTokens: maxTokens,
                            resumingFrom: partialText, control: control,
                            errors: errors,
                            emit: { sink.yield($0) }
                        )
                    }
                }()
                for await event in events {
                    if case .text(let text) = event { generatedText += text }
                    onEvent(event)
                }
                stopReason = try await outcome
            } catch {
                let paused = control.finishRun()
                // Prompt processing can't be interrupted, so GPU work may
                // still be in flight when iOS suspends the app, and fail
                // once it returns. The reply was pausing anyway: carry on
                // from the text so far.
                if paused, error is MLXError, !control.isStopped, !Task.isCancelled {
                    Log.localModels.notice("Resuming after an MLX error while paused: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                throw error
            }
            let paused = control.finishRun()
            try Task.checkCancellation()
            // Only a run cut short by the pause continues. One that ended
            // on its own (end of turn, token limit) as the pause came in
            // is done.
            guard paused, stopReason == .cancelled else { return }
        }
    }

    /// One stretch of generation. Returns only once MLX's generation task
    /// has ended and synchronized, so the GPU is idle. Returns `.length` if the token budget is already
    /// spent.
    @concurrent
    private static func run(
        history: [LocalMLX.Turn],
        tools: [[String: any Sendable]]?,
        container: ModelContainer,
        parameters: GenerateParameters,
        maxTokens: Int,
        resumingFrom partialText: String,
        control: GenerationControl,
        errors: ErrorBox,
        emit: @escaping @Sendable (LocalMLX.GenerationEvent) -> Void
    ) async throws -> GenerateStopReason? {
        var input: LMInput
        do {
            input = try await container.prepare(input: UserInput(chat: history.map(chatMessage), tools: tools))
        } catch where tools != nil && !(error is CancellationError) {
            throw LocalMLX.ToolsUnsupported()
        }

        var parameters = parameters
        if !partialText.isEmpty {
            // The template ends with the assistant's turn opening, so the
            // partial reply follows straight on, without closing the turn.
            let tokenizer = await container.tokenizer
            guard let resume = GenerationResume.continuation(
                templateTokens: input.text.tokens.asArray(Int.self),
                partialText: partialText,
                maxTokens: maxTokens,
                encode: { tokenizer.encode(text: $0, addSpecialTokens: false) }
            ) else { return .length }
            input = LMInput(tokens: MLXArray(resume.prompt))
            parameters.maxTokens = resume.maxTokens
        }
        try Task.checkCancellation()

        // Same as `ModelContainer.generate`, but keeps MLX's task so this can
        // wait for it to end.
        let generateParameters = parameters
        let (stream, task) = try await container.perform(nonSendable: input) { context, input in
            let iterator = try TokenIterator(input: input, model: context.model, parameters: generateParameters)
            return MLXLMCommon.generateTask(
                promptTokenCount: input.text.tokens.size,
                modelConfiguration: context.configuration,
                tokenizer: context.tokenizer,
                iterator: iterator,
                toolCallPolicy: generateParameters.toolCallPolicy
            )
        }
        // MLX checks for cancellation before each step, then synchronizes.
        control.attach { task.cancel() }

        var stopReason: GenerateStopReason?
        for await generation in stream {
            // Once an eval has failed, MLX's task keeps stepping on bad
            // results until it's cancelled. Stop it and drop its output.
            if errors.firstError != nil {
                task.cancel()
                break
            }
            switch generation {
            case .chunk(let text) where !text.isEmpty:
                emit(.text(text))
            case .toolCall(let call):
                emit(.toolCall(Self.toolRequest(call)))
            case .info(let info):
                stopReason = info.stopReason
            default:
                break
            }
        }
        // The stream also ends early if this task is cancelled.
        if Task.isCancelled { task.cancel() }
        await task.value
        if let error = errors.firstError { throw error }
        return stopReason
    }

    private static func chatMessage(_ turn: LocalMLX.Turn) -> Chat.Message {
        switch turn {
        case .message(let message):
            switch message.role {
            case .system: return .system(message.content)
            case .assistant: return .assistant(message.content)
            case .user: return .user(message.content)
            }
        case .toolCalls(let text, let calls):
            return .assistant(text, toolCalls: calls.map { call in
                let arguments: [String: JSONValue] = call.query.map { ["query": .string($0)] } ?? [:]
                return ToolCall(function: ToolCall.Function(name: call.name, arguments: arguments), id: call.id)
            })
        case .toolResult(let id, let name, let content):
            return .tool(content, id: id, name: name)
        }
    }

    private static func toolRequest(_ call: ToolCall) -> LocalMLX.ToolRequest {
        var query: String?
        if case .string(let value) = call.function.arguments["query"] {
            query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return LocalMLX.ToolRequest(id: call.id, name: call.function.name, query: query)
    }
}

#endif
