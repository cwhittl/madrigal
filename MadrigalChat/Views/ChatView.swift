import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ProviderConfig.createdAt) private var providers: [ProviderConfig]
    @Query(sort: \Agent.createdAt) private var agents: [Agent]

    @Bindable var conversation: Conversation
    /// Published to the window so the menu bar's Stop Generating works.
    @Binding var stopGenerating: (() -> Void)?
    /// Opens Settings at the provider presets.
    let addProvider: () -> Void

    @State private var viewModel = ChatViewModel()
    /// Scroll geometry and follow state, deliberately not observed.
    @State private var scrollTracker = TranscriptScrollTracker()
    @State private var showsJumpButton = false
    @State private var showingModelPicker = false
    @State private var exportDocument: MarkdownDocument?
    @State private var confirmingRegenerate: Message?

    private let bottomAnchor = "chat-bottom"
    private let transcriptSpace = "chat-transcript"

    // This body must not read `viewModel.streamingContent` or `draft`: it
    // would then re-run, and re-render every visible message, on each
    // streamed update and keystroke. Rows and the composer read those.

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            ChatComposer(conversation: conversation, viewModel: viewModel, providers: providers, agents: agents) {
                viewModel.send(in: conversation, configs: providers, context: context)
            }
        }
        .navigationTitle(conversation.title)
        // The view is re-created per conversation (.id in RootSplitView), so
        // an in-flight stream would otherwise keep running with no owner.
        // Leaving is also when a project chat's summary catches up.
        .onDisappear {
            if viewModel.isStreaming { viewModel.stop() }
            stopGenerating = nil
            viewModel.summarizeIfNeeded(conversation, configs: providers, context: context)
        }
        .onChange(of: viewModel.isStreaming) { _, streaming in
            stopGenerating = streaming ? { [viewModel] in viewModel.stop() } : nil
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showingModelPicker = true
                } label: {
                    if let agent = conversation.agent(in: agents) {
                        Label(agent.name, systemImage: agent.iconSystemName)
                    } else {
                        let model = currentModel
                        Label(model.isEmpty ? "Choose model" : Self.shortModelName(model),
                              systemImage: "cpu")
                    }
                }
                .disabled(providers.isEmpty)
            }
            ToolbarItem(placement: .automatic) {
                exportMenu
            }
        }
        .fileExporter(
            isPresented: $exportDocument.isPresent(),
            document: exportDocument,
            contentType: MarkdownDocument.markdownType,
            defaultFilename: ConversationExporter.filename(for: conversation)
        ) { _ in }
        .confirmationDialog(
            "Regenerate this reply?",
            isPresented: $confirmingRegenerate.isPresent(),
            titleVisibility: .visible,
            presenting: confirmingRegenerate
        ) { message in
            Button("Regenerate", role: .destructive) {
                viewModel.regenerate(message, in: conversation, configs: providers, context: context)
            }
            Button("Cancel", role: .cancel) { }
        } message: { message in
            let count = viewModel.messagesAfter(message, in: conversation)
            Text("The \(count) \(count == 1 ? "message" : "messages") after it will be removed.")
        }
        .sheet(isPresented: $showingModelPicker) {
            NavigationStack {
                ModelPickerView(conversation: conversation)
            }
            .macSheetSize(minWidth: 420, minHeight: 360)
        }
    }

    private var exportMenu: some View {
        Menu {
            Button("Copy as Markdown", systemImage: "doc.on.doc") {
                Clipboard.copy(ConversationExporter.markdown(for: conversation))
            }
            ShareLink(
                item: ConversationMarkdownExport(conversation),
                subject: Text(conversation.title),
                preview: SharePreview(conversation.title)
            ) {
                Label("Share\u{2026}", systemImage: "square.and.arrow.up")
            }
            Button("Export Markdown File\u{2026}", systemImage: "arrow.down.doc") {
                exportDocument = MarkdownDocument(text: ConversationExporter.markdown(for: conversation))
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        // Not sendableMessages: that reads every message's content, which
        // would make this view re-render on each mid-stream save.
        .disabled(viewModel.isStreaming || (conversation.messages ?? []).isEmpty)
    }

    /// `@cf/meta/llama-3.1-8b-instruct` is too long for a toolbar button, and
    /// Cloudflare model IDs are path-shaped, so show the last component.
    private static func shortModelName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    /// What this chat sends to on this device. For MLX that can differ from
    /// the synced `modelID` when it isn't downloaded here.
    private var currentModel: String {
        conversation.resolveConfig(among: providers).map { conversation.chosenModel(config: $0) }
            ?? conversation.modelID
    }

    // MARK: - Transcript

    private var transcript: some View {
        let messages = conversation.orderedMessages
        let lastUser = messages.last { $0.role == .user }
        let idle = !viewModel.isStreaming

        return ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    // Not lazy: every row is measured up front, so scrolling
                    // up never meets an estimated height that then jumps.
                    VStack(alignment: .leading, spacing: 20) {
                        if messages.isEmpty {
                            emptyPrompt
                                .padding(.top, 60)
                        }
                        ForEach(messages, id: \.stableID) { message in
                            TranscriptRow(
                                message: message,
                                viewModel: viewModel,
                                // Retrying an older error would re-run the whole
                                // chat and append a reply at the end, so only the
                                // latest turn offers it.
                                onRetry: message === messages.last && idle
                                    ? { viewModel.retry(in: conversation, configs: providers, context: context) }
                                    : nil,
                                onRegenerate: message.role == .assistant && !message.isError && idle
                                    ? { regenerate(message) }
                                    : nil,
                                onEdit: message === lastUser && idle
                                    ? { viewModel.editLastUserMessage(in: conversation, context: context) }
                                    : nil
                            )
                            .id(message.stableID)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchor)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background {
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named(transcriptSpace))
                            Color.clear.onChange(of: frame, initial: true) { _, frame in
                                scrollTracker.contentFrame = frame
                                followGeometry(proxy)
                            }
                        }
                    }
                }
                .coordinateSpace(name: transcriptSpace)
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                            scrollTracker.viewportHeight = height
                            followGeometry(proxy)
                        }
                    }
                }
                .transcriptStartsAtBottom()
                .scrollDismissesKeyboard(.interactively)
                .environment(\.transcriptScrollTracker, scrollTracker)
                .onChange(of: messages.count) { _, _ in
                    scrollTracker.resumeFollowing()
                    showsJumpButton = false
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }

                if showsJumpButton {
                    Button {
                        scrollTracker.resumeFollowing()
                        showsJumpButton = false
                        withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.callout)
                            .padding(.horizontal, 14)
                            #if os(iOS)
                            .padding(.vertical, 10)
                            #else
                            .padding(.vertical, 8)
                            #endif
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    /// Runs on every geometry change of the transcript. Scrolls without
    /// animation, or the follow can overshoot and bounce back, and touches
    /// `@State` only when the button's visibility actually flips.
    private func followGeometry(_ proxy: ScrollViewProxy) {
        guard scrollTracker.viewportHeight > 0 else { return }
        if scrollTracker.update() == .scrollToBottom {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
        let shows = scrollTracker.state.showsJumpButton
        if shows != showsJumpButton { showsJumpButton = shows }
    }

    /// Regenerating an older reply drops what came after it, so ask first.
    private func regenerate(_ message: Message) {
        if viewModel.messagesAfter(message, in: conversation) > 0 {
            confirmingRegenerate = message
        } else {
            viewModel.regenerate(message, in: conversation, configs: providers, context: context)
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 8) {
            Image(.madrigalMark)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .opacity(0.85)
                .padding(.bottom, 8)

            if providers.isEmpty {
                Text("No provider yet")
                    .font(.headline)
                Text("Choose from OpenAI, Anthropic, Gemini, OpenRouter, local servers, and more.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Add Provider", action: addProvider)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            } else if let agent = conversation.agent(in: agents) {
                Image(systemName: agent.iconSystemName)
                    .font(.title2)
                    .foregroundStyle(Color(hex: agent.colorHex))
                Text("Chatting with \(agent.name)")
                    .font(.headline)
                Text((conversation.project.map { "In \($0.displayName). " } ?? "")
                     + "This agent's instructions are applied to every message.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let project = conversation.project, !project.customInstructions.isEmpty {
                Text("Chatting in \(project.displayName)")
                    .font(.headline)
                Text("This project's custom instructions are applied to every message.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Ask anything.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One message in the transcript. Only the row being streamed into reads the
/// view model's live text, so only it re-renders as tokens arrive.
private struct TranscriptRow: View {
    let message: Message
    let viewModel: ChatViewModel
    let onRetry: (() -> Void)?
    let onRegenerate: (() -> Void)?
    let onEdit: (() -> Void)?

    var body: some View {
        let streaming = viewModel.streamingMessage === message
        let content = streaming ? viewModel.streamingContent : message.content
        let reasoning = streaming ? viewModel.streamingReasoning : message.reasoning

        MessageBubbleView(
            message: message,
            content: content,
            reasoning: reasoning,
            isStreaming: streaming,
            status: streaming ? viewModel.streamingStatus : "",
            // Written once, when the stream finishes.
            searches: streaming || message.role != .assistant
                ? [] : ToolPayload(json: message.toolPayloadJSON).webSearch,
            onRetry: onRetry,
            onRegenerate: onRegenerate,
            onEdit: onEdit
        )
    }
}
