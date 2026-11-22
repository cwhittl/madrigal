import Foundation
import SwiftData
import Observation
#if os(iOS)
import UIKit
#endif

/// Owns the send/stream/stop/retry lifecycle for one conversation.
@Observable
@MainActor
final class ChatViewModel {

    var draft: String = ""
    private(set) var isStreaming: Bool = false
    /// True while the post-reply project summary is being written, so the
    /// UI can show that work is still happening after the stream ends.
    private(set) var isSummarizing: Bool = false
    /// The assistant message currently being filled in by the stream, if any.
    /// Held by reference, not persistentModelID: a new message's ID is
    /// temporary and changes when autosave runs mid-stream, which would
    /// make the bubble stop treating itself as streaming.
    private(set) var streamingMessage: Message?
    /// Live text of `streamingMessage`. While streaming, the bubble reads
    /// these instead of the model: writing every token to SwiftData would
    /// trigger an autosave and a CloudKit export per token.
    private(set) var streamingContent: String = ""
    private(set) var streamingReasoning: String = ""
    /// What the provider is doing instead of writing, such as a web search.
    private(set) var streamingStatus: String = ""

    private var streamTask: Task<Void, Never>?
    /// Bumped on every send and every stop. A finishing stream only writes
    /// back its own state if the token still matches, so a stopped stream
    /// can never clobber the one that replaced it.
    private var runToken: Int = 0

    @ObservationIgnored private let notifier: ReplyNotifier
    @ObservationIgnored private let screenAwake: any ScreenAwakeHolding
    @ObservationIgnored private let inFlight: InterruptedReplies

    /// The shared services by default; tests pass their own.
    init(
        notifier: ReplyNotifier = .shared,
        screenAwake: any ScreenAwakeHolding = ScreenAwakeService.shared,
        inFlight: InterruptedReplies = .shared
    ) {
        self.notifier = notifier
        self.screenAwake = screenAwake
        self.inFlight = inFlight
    }

    /// How often streamed text reaches the UI (about 30 Hz).
    static let displayInterval: Duration = .milliseconds(33)
    /// How often streamed text is written to the model mid-stream, so a
    /// crash loses at most this much of a reply.
    static let persistInterval: Duration = .seconds(1)
    /// A project chat's summary is refreshed after this many new messages,
    /// and otherwise when the user leaves the chat.
    static let summaryMessageInterval = 6

    // MARK: - Sending

    func send(in conversation: Conversation, configs: [ProviderConfig], context: ModelContext) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        let user = Message(role: .user, content: text)
        // Insert first, then relate: assigning a relationship before the
        // object is in the context leaves the inverse unset for a beat.
        context.insert(user)
        user.conversation = conversation
        draft = ""
        conversation.autoTitleIfNeeded()
        conversation.touch()
        // Normally asked at first launch (see RootSplitView); this is a
        // fallback, and does nothing once the user has decided.
        notifier.requestAuthorizationIfNeeded()

        run(in: conversation, configs: configs, context: context)
    }

    /// Re-runs the last turn without duplicating the user's message.
    func retry(in conversation: Conversation, configs: [ProviderConfig], context: ModelContext) {
        guard !isStreaming else { return }

        // Drop a trailing failed or empty assistant message, then resend.
        if let last = conversation.orderedMessages.last,
           last.role == .assistant,
           last.isError || last.content.isEmpty {
            context.delete(last)
            // ContextAssembler reads orderedMessages immediately below, and
            // the delete isn't visible there until pending changes flush.
            context.processPendingChanges()
        }
        run(in: conversation, configs: configs, context: context)
    }

    /// Replaces an assistant reply with a fresh one. Anything after it is
    /// removed too, since it was a response to the old reply.
    func regenerate(_ message: Message, in conversation: Conversation, configs: [ProviderConfig], context: ModelContext) {
        guard !isStreaming, message.role == .assistant else { return }
        deleteMessages(from: message, in: conversation, context: context)
        run(in: conversation, configs: configs, context: context)
    }

    /// Moves the last user message back into the composer and removes it
    /// and its reply, so it can be edited and sent again.
    func editLastUserMessage(in conversation: Conversation, context: ModelContext) {
        guard !isStreaming, let last = conversation.lastUserMessage else { return }
        draft = last.content
        deleteMessages(from: last, in: conversation, context: context)
    }

    /// Number of messages after `message`, which regenerating it would remove.
    func messagesAfter(_ message: Message, in conversation: Conversation) -> Int {
        conversation.orderedMessages.filter { $0.createdAt > message.createdAt }.count
    }

    private func deleteMessages(from message: Message, in conversation: Conversation, context: ModelContext) {
        for candidate in conversation.orderedMessages where candidate.createdAt >= message.createdAt {
            context.delete(candidate)
        }
        context.processPendingChanges()
        conversation.touch()
    }

    private func run(in conversation: Conversation, configs: [ProviderConfig], context: ModelContext) {
        guard let config = conversation.resolveConfig(among: configs) else {
            appendError("No provider configured. Add one in Settings.", to: conversation, context: context)
            return
        }

        let model = conversation.chosenModel(config: config)
        guard !model.isEmpty else {
            appendError("No model selected for \(config.name). Pick one in Settings.", to: conversation, context: context)
            return
        }

        // The secrets are read from the Keychain when the stream starts,
        // off the main actor; only the checks that don't need them run here.
        let recipe: ProviderRecipe
        do {
            recipe = try ProviderFactory.recipe(for: config)
        } catch {
            appendError(Self.describe(error, provider: config.name), to: conversation, context: context)
            return
        }

        if let problem = config.webSearchProblem {
            appendError("Web search is on for \(config.name), but it isn't set up: \(problem) Fix it in Settings, or turn web search off.", to: conversation, context: context)
            return
        }
        let webSearch = ProviderFactory.makeWebSearch(for: config)

        // Remember what this conversation is talking to.
        conversation.providerLabel = config.name
        conversation.providerKeychainKey = config.keychainKey
        // An MLX model may be this device's fallback or its own pick; either
        // way it stays on this device. `assistant.modelID` still records it.
        if config.kind != .localMLX {
            conversation.modelID = model
        }

        let agent = Agent.find(conversation.agentID, in: context)
        let outgoing = ContextAssembler.build(
            for: conversation,
            globalInstructions: UserDefaults.standard.string(forKey: AppConfig.globalInstructionsKey) ?? "",
            agent: agent,
            // Leaves room for one search's results.
            characterCap: config.effectiveContextLimit - Self.webSearchReserve(for: webSearch)
        )
        var options = agent?.generationOptions(over: config.generationOptions) ?? config.generationOptions
        options.webSearch = webSearch
        let providerName = config.name
        // On-device MLX models use Metal, so their background task asks for
        // GPU access (iOS 26, M3 and later iPads). Without it they pause in
        // the background and carry on when the app returns.
        let compute: BackgroundActivity.Compute = config.kind == .localMLX ? .gpuIfSupported : .cpu
        let conversationID = conversation.stableID

        let assistant = Message(role: .assistant, content: "")
        assistant.modelID = model
        context.insert(assistant)
        assistant.conversation = conversation

        streamingMessage = assistant
        streamingContent = ""
        streamingReasoning = ""
        streamingStatus = ""
        isStreaming = true
        screenAwake.begin()
        // Cleared when the reply ends; if the app ends first, the next
        // launch marks the reply as interrupted.
        inFlight.begin(conversationID)
        let inFlight = self.inFlight

        runToken += 1
        let token = runToken

        // Keeps the request alive if the user switches apps or locks the
        // screen: until it finishes on iOS 26+, about 30 s before that.
        // The system's progress banner only appears once the user leaves,
        // and an on-device reply learns through the box whether it may
        // keep using the GPU then.
        let backgroundCompute = BackgroundComputeBox()
        options.backgroundCompute = backgroundCompute
        let background = BackgroundActivity(
            name: "Streaming reply",
            title: conversation.title,
            compute: compute,
            computeBox: backgroundCompute
        ) { [weak self] in
            guard let self, self.runToken == token else { return }
            self.stop()
        }

        // Captured so the notification still goes out if this view model
        // is gone by the time the reply ends.
        let notifier = self.notifier

        // Saves the text so far when the app leaves. A paused on-device
        // reply may never resume if iOS ends the suspended app, so this
        // keeps everything up to that moment rather than the last periodic
        // write. An on-device reply without background GPU access pauses
        // now, so the user is told it waits for them to come back.
        #if os(iOS)
        let backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.runToken == token else { return }
                if self.writeStreamingText() {
                    self.streamingMessage?.modelContext?.saveOrLog("reply text on leaving the app")
                }
                // The box is final by now: willResignActive, where the
                // background task is submitted, always comes first.
                if compute == .gpuIfSupported, backgroundCompute.value == .pause,
                   let chat = self.streamingMessage?.conversation, chat.isLive {
                    notifier.replyPaused(conversationID: conversationID, title: chat.title)
                }
            }
        }
        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { notifier.replyResumed(conversationID: conversationID) }
        }
        #endif
        streamTask = Task { [weak self] in
            // Token handling happens off the main actor in StreamAccumulator.
            // This loop only wakes for snapshots, at most once per
            // displayInterval, and does the cheap main-actor work: updating
            // the UI and occasionally the model.
            var latest = StreamSnapshot()
            var searches: [WebSearchRecord] = []
            var failure: Error?
            let clock = ContinuousClock()
            var lastPersist = clock.now

            do {
                let provider = try await recipe.makeProvider()
                var outgoing = outgoing
                // Searched once here rather than in each provider. The
                // providers handle "auto" mode, where the model decides.
                if let webSearch, webSearch.mode == .always,
                   let query = outgoing.last(where: { $0.role == .user })?.content {
                    if let self, self.runToken == token {
                        self.streamingStatus = WebSearchConfig.statusText(for: query)
                    }
                    // Shows later steps, like reading pages, as they start.
                    let searched = await webSearch.injectingResults(into: outgoing) { [weak self] delta in
                        guard !delta.status.isEmpty else { return }
                        Task { @MainActor in
                            if let self, self.runToken == token { self.streamingStatus = delta.status }
                        }
                    }
                    try Task.checkCancellation()
                    outgoing = searched.messages
                    if let record = searched.record { searches.append(record) }
                }

                let deltas = provider.streamCompletion(messages: outgoing, model: model, options: options)
                for try await snapshot in StreamAccumulator.snapshots(of: deltas, every: Self.displayInterval) {
                    latest = snapshot
                    background.update()
                    if let self, self.runToken == token {
                        self.streamingContent = snapshot.answer
                        self.streamingReasoning = snapshot.reasoning
                        self.streamingStatus = snapshot.status
                    }
                    let now = clock.now
                    if now - lastPersist >= Self.persistInterval, assistant.isLive {
                        lastPersist = now
                        assistant.content = snapshot.answer
                        assistant.reasoning = snapshot.reasoning
                    }
                }
            } catch is CancellationError {
                // Stopped by the user. Keep whatever text arrived.
            } catch {
                failure = error
            }

            #if os(iOS)
            NotificationCenter.default.removeObserver(backgroundObserver)
            NotificationCenter.default.removeObserver(foregroundObserver)
            #endif
            notifier.replyResumed(conversationID: conversationID)
            inFlight.end(conversationID)
            let cancelled = Task.isCancelled
            // A stop can surface as URLError.cancelled; it isn't a failure.
            if cancelled { failure = nil }
            let expired = background.expired
            let cutOffReason = background.expiryReason
            background.end(success: failure == nil && !cancelled)

            // The chat may have been deleted mid-stream. Writing to a deleted
            // model crashes, so leave everything as it is.
            if assistant.isLive && conversation.isLive {
                let answer = latest.answer, reasoning = latest.reasoning
                if cancelled && answer.isEmpty && reasoning.isEmpty {
                    // Stopped before anything arrived: don't leave a blank turn.
                    context.delete(assistant)
                } else {
                    assistant.content = answer
                    assistant.reasoning = reasoning
                    assistant.toolPayloadJSON = ToolPayload(webSearch: searches + latest.searches).json
                    if let failure {
                        assistant.isError = true
                        assistant.errorDescription = Self.describe(failure, provider: providerName)
                    } else if !latest.received && !cancelled {
                        assistant.isError = true
                        assistant.errorDescription = "The model returned an empty response."
                    }
                }
                conversation.touch()
                context.saveOrLog("finished reply")

                let outcome: ReplyOutcome? = if expired {
                    .cutOff(reason: cutOffReason)
                } else if assistant.isLive && assistant.isError {
                    .failed
                } else if !cancelled {
                    .finished(answer: answer)
                } else {
                    nil  // Stopped by the user, who is looking at it.
                }
                if let outcome {
                    notifier.replyFinished(conversationID: conversationID, title: conversation.title, outcome: outcome)
                }

                // Refresh this chat's summary for the project's other chats
                // every few messages; leaving the chat catches the rest.
                let completed = !cancelled && failure == nil && !assistant.isError
                if completed,
                   conversation.sendableMessages.count - conversation.summarizedMessageCount >= Self.summaryMessageInterval {
                    self?.summarizeIfNeeded(conversation, configs: configs, context: context)
                }
            }

            // Only the current run owns the view model's streaming state.
            guard let self, self.runToken == token else { return }
            self.finishStreaming()
        }
    }

    /// Writes the live text to the streaming message, rather than leaving
    /// the last ~1 s write. Returns false if there was nothing to write.
    @discardableResult
    private func writeStreamingText() -> Bool {
        guard let message = streamingMessage, message.isLive,
              !streamingContent.isEmpty || !streamingReasoning.isEmpty else { return false }
        message.content = streamingContent
        message.reasoning = streamingReasoning
        return true
    }

    func stop() {
        // Show the latest text right away.
        writeStreamingText()
        runToken += 1
        streamTask?.cancel()
        finishStreaming()
    }

    private func finishStreaming() {
        // Balances the begin() in run(). Guarded so a stray second finish
        // can't release another window's hold on the screen.
        if isStreaming { screenAwake.end() }
        streamTask = nil
        isStreaming = false
        streamingMessage = nil
        streamingContent = ""
        streamingReasoning = ""
        streamingStatus = ""
    }

    /// Context characters set aside for search results: one search's worth
    /// plus the note that introduces them. MLX "auto" mode can search up to
    /// `LocalMLX.maxSearchRounds` times, but reserving for all of them would
    /// take more than its whole default budget and leave no history, so
    /// later rounds can run past the limit instead.
    nonisolated static func webSearchReserve(for webSearch: WebSearchConfig?) -> Int {
        guard let webSearch else { return 0 }
        return webSearch.characterCap + 250
    }

    // MARK: - Project summaries

    /// Writes this chat's summary for the project's other chats if it has
    /// changed since the last one. Detached so the UI never waits on it, and
    /// safe to call as the chat closes. Skipped while one is already being
    /// written: `summarizedMessageCount` only moves when it finishes, so a
    /// second call would send the same request again.
    func summarizeIfNeeded(_ conversation: Conversation, configs: [ProviderConfig], context: ModelContext) {
        guard !isSummarizing,
              conversation.isLive,
              conversation.project?.shareChatSummaries == true,
              conversation.needsSummary,
              let config = conversation.resolveConfig(among: configs)
        else { return }

        let summaryModel = config.summaryModel
        let model = summaryModel.isEmpty
            ? conversation.chosenModel(config: config)
            : summaryModel
        guard !model.isEmpty, let recipe = try? ProviderFactory.recipe(for: config) else { return }

        isSummarizing = true
        Task { [weak self] in
            // Reads the Keychain off the main actor.
            if let provider = try? await recipe.makeProvider() {
                await ConversationSummarizer.summarize(
                    conversation, provider: provider, model: model, context: context
                )
            }
            self?.isSummarizing = false
        }
    }

    // MARK: - Helpers

    private func appendError(_ text: String, to conversation: Conversation, context: ModelContext) {
        let message = Message(role: .assistant, content: "")
        message.isError = true
        message.errorDescription = text
        context.insert(message)
        message.conversation = conversation
        conversation.touch()
    }

    /// Turns a provider error into copy that names the provider, per spec section 10.
    nonisolated static func describe(_ error: Error, provider: String) -> String {
        if let providerError = error as? ChatProviderError {
            switch providerError {
            case .missingAPIKey:
                return "No key found for \(provider). Check Settings."
            case .missingAccountID:
                return "No Cloudflare account ID set for \(provider). Check Settings."
            case .http(let status, _) where status == 401 || status == 403:
                return "Invalid credentials for \(provider)."
            case .http(let status, _) where status == 429:
                return "Rate limited by \(provider). Try again shortly."
            case .streamError(let message):
                return "\(provider) reported an error: \(message)"
            default:
                return providerError.errorDescription ?? "\(provider) request failed."
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            let code = (error as NSError).code
            if code == NSURLErrorNotConnectedToInternet || code == NSURLErrorNetworkConnectionLost {
                return "You're offline."
            }
            if code == NSURLErrorTimedOut {
                return "\(provider) took too long to respond."
            }
        }
        return error.localizedDescription
    }
}
