import SwiftUI

/// One turn in the transcript: user = bubble, assistant = flowing text.
struct MessageBubbleView: View {
    let message: Message
    /// Passed in rather than read from `message`: while streaming, the live
    /// text lives in the view model and is written to the model less often.
    let content: String
    let reasoning: String
    let isStreaming: Bool
    /// What the provider is doing instead of writing, such as a web search.
    var status: String = ""
    /// The reply's sources, decoded once by the caller rather than on every
    /// render. Empty while streaming.
    var searches: [WebSearchRecord] = []
    /// Each action is nil where it doesn't apply, which hides its button.
    var onRetry: (() -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil

    @State private var isSelectingText = false

    /// Whitespace-only chunks (often the first ones) render as nothing, so
    /// they shouldn't count as the answer having started.
    private var hasVisibleContent: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isThinking: Bool {
        isStreaming && !reasoning.isEmpty && !hasVisibleContent
    }

    /// What the stream is doing right now, shown in the status box.
    private var activity: String {
        if !status.isEmpty { return status }
        if isThinking { return "Thinking\u{2026}" }
        if hasVisibleContent { return "Writing\u{2026}" }
        return "Waiting for a reply\u{2026}"
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 40)
                    Text(content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(content) }
                            Button("Select Text", systemImage: "text.cursor") { isSelectingText = true }
                            if let onEdit {
                                Button("Edit", systemImage: "pencil", action: onEdit)
                            }
                        }
                }
                // The context menu is easy to miss on touch, so editing also
                // gets a visible button.
                if let onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(Self.footerIconFont)
                    }
                    .buttonStyle(.borderless)
                    .touchTarget()
                    .foregroundStyle(.tertiary)
                    .help("Edit")
                    .accessibilityLabel("Edit message")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if message.isError {
                    // Text that arrived before the failure or interruption
                    // stays readable above the error.
                    if hasVisibleContent {
                        MarkdownText(content: content)
                    }
                    errorView
                } else {
                    // Up for the whole stream, not just until the first
                    // chunk, so a pause mid-answer doesn't look like the end.
                    // Afterwards only if there's reasoning to read.
                    if isStreaming || !reasoning.isEmpty {
                        ThinkingView(
                            reasoning: reasoning,
                            isThinking: isThinking,
                            activity: isStreaming ? activity : nil
                        )
                    }
                    // Not until there's text: an empty block would still
                    // take a row of spacing under the status box.
                    if hasVisibleContent {
                        MarkdownText(content: content)
                    }
                    if !isStreaming && !searches.isEmpty {
                        SourcesView(searches: searches)
                    }
                }
                if !isStreaming && !message.isError {
                    assistantFooter
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // macOS only: on iOS a long press lifts the whole reply as a
            // preview and fights text selection, and the footer already has
            // these actions. Over the reply's text the native menu, with Copy
            // for the selection, takes the right-click instead.
            #if os(macOS)
            .contextMenu {
                if !message.isError && !content.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(content) }
                }
                if let onRegenerate {
                    Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
                }
            }
            #endif
        case .system:
            EmptyView()
        }
    }

    var body: some View {
        bubble
            .sheet(isPresented: $isSelectingText) {
                SelectableTextSheet(content: content)
            }
    }

    private var assistantFooter: some View {
        // touchTarget() already spaces the icons out on iOS.
        HStack(spacing: Self.footerSpacing) {
            if !content.isEmpty {
                Button { Clipboard.copy(content) } label: {
                    Image(systemName: "doc.on.doc")
                        .font(Self.footerIconFont)
                }
                .touchTarget()
                .help("Copy")
                .accessibilityLabel("Copy reply")
            }
            if let onRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(Self.footerIconFont)
                }
                .touchTarget()
                .help("Regenerate")
                .accessibilityLabel("Regenerate reply")
            }
            if !message.modelID.isEmpty {
                Text(message.modelID)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.borderless)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    /// A step up from the footer's caption2 on iOS, where the icons are tapped.
    private static var footerIconFont: Font {
        #if os(iOS)
        .footnote
        #else
        .caption2
        #endif
    }

    private static var footerSpacing: CGFloat {
        #if os(iOS)
        4
        #else
        12
        #endif
    }

    private var errorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message.errorDescription.isEmpty ? "Something went wrong." : message.errorDescription,
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The web searches behind a reply and what they found, numbered as the
/// model was asked to cite them. Collapsed by default.
private struct SourcesView: View {
    let searches: [WebSearchRecord]

    #if DEBUG
    // Open in screenshots, so they show what was found.
    @State private var isExpanded = ScreenshotDemo.isActive
    #else
    @State private var isExpanded = false
    #endif

    private var resultCount: Int {
        searches.reduce(0) { $0 + $1.results.count }
    }

    private var everySearchFailed: Bool {
        searches.allSatisfy { $0.failure != nil }
    }

    private var summary: String {
        if everySearchFailed { return searches.count == 1 ? "Search failed" : "Searches failed" }
        switch resultCount {
        case 0: return "No sources found"
        case 1: return "1 source"
        default: return "\(resultCount) sources"
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(searches.enumerated()), id: \.offset) { _, search in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(search.query, systemImage: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let failure = search.failure {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if search.results.isEmpty {
                            Text("No results")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(search.results.enumerated()), id: \.offset) { index, result in
                            sourceRow(number: index + 1, result: result)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label(summary, systemImage: everySearchFailed ? "exclamationmark.triangle" : "globe")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func sourceRow(number: Int, result: SearchResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("[\(number)]")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let url = URL(string: result.url), url.isSafeToOpen {
                    Link(result.title, destination: url)
                        .font(.callout)
                } else {
                    Text(result.title).font(.callout)
                }
                Text(URL(string: result.url)?.host() ?? result.url)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// The status box above an assistant reply. While streaming it says what
/// the model is doing (waiting, searching, thinking, writing); afterwards it
/// holds the reasoning, if any, as "Thought process". Reasoning is collapsed
/// by default; with the "expand thinking" preference on, it opens while the
/// model thinks and collapses once the answer starts.
private struct ThinkingView: View {
    let reasoning: String
    let isThinking: Bool
    /// What's happening now, or nil once the stream has finished.
    let activity: String?

    @State private var isExpanded: Bool
    /// Set when we opened it ourselves, so the auto-collapse never closes
    /// a panel the user opened by tapping.
    @State private var autoOpened: Bool

    init(reasoning: String, isThinking: Bool, activity: String?) {
        self.reasoning = reasoning
        self.isThinking = isThinking
        self.activity = activity
        // @AppStorage isn't readable in init. Covers a row rebuilt mid-thought.
        let open = isThinking && Self.expandsWhileThinking
        _isExpanded = State(initialValue: open)
        _autoOpened = State(initialValue: open)
    }

    private static var expandsWhileThinking: Bool {
        UserDefaults.standard.bool(forKey: AppConfig.expandThinkingKey)
    }

    var body: some View {
        Group {
            if reasoning.isEmpty {
                label
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    Text(reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    label
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        // Not animated: the transcript is pinned to the bottom while
        // streaming, and an animated height change leaves it scrolled past
        // the end of the content.
        .onChange(of: isThinking) { _, thinking in
            if thinking {
                // The box usually exists before reasoning arrives, so init
                // alone wouldn't catch the start of a thought.
                if !isExpanded, Self.expandsWhileThinking {
                    isExpanded = true
                    autoOpened = true
                }
            } else if autoOpened {
                isExpanded = false
                autoOpened = false
            }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if let activity {
                MadrigalIndicator(size: .mini, label: activity)
                Text(activity)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Image(systemName: "brain")
                Text("Thought process")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
