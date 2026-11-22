import SwiftUI

/// The message field and send/stop button. Its own view so typing doesn't
/// re-render the transcript.
struct ChatComposer: View {
    let conversation: Conversation
    @Bindable var viewModel: ChatViewModel
    let providers: [ProviderConfig]
    let agents: [Agent]
    let onSend: () -> Void

    @Environment(\.isOnline) private var isOnline

    var body: some View {
        let config = conversation.resolveConfig(among: providers)
        let canSend = Self.canSend(draft: viewModel.draft, providers: providers, config: config, isOnline: isOnline)
        VStack(spacing: 6) {
            if let notice = Self.offlineNotice(config: config, isOnline: isOnline) {
                Label(notice, systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ComposerField(text: $viewModel.draft) { send(canSend: canSend) }
                    .disabled(providers.isEmpty)

                if viewModel.isStreaming {
                    Button(action: viewModel.stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .touchTarget()
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Stop generating (Esc)")
                    .accessibilityLabel("Stop generating")
                } else {
                    Button { send(canSend: canSend) } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .touchTarget()
                    .disabled(!canSend)
                    .help("Send (Return) \u{00B7} New line (Shift/Option/Control-Return)")
                    .accessibilityLabel("Send message")
                }
            }

            if let config {
                HStack(spacing: 4) {
                    Text(config.name)
                    let name = conversation.displayModelName(agents: agents, config: config)
                    if !name.isEmpty {
                        Text("\u{00B7}")
                        Text(name)
                    }
                    Spacer()
                    if viewModel.isSummarizing {
                        MadrigalIndicator(size: .mini)
                        Text("Updating project summary\u{2026}")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    /// On-device models still answer offline; only hosted ones need the
    /// network.
    static func canSend(draft: String, providers: [ProviderConfig], config: ProviderConfig?, isOnline: Bool) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !providers.isEmpty
            && (isOnline || config?.kind.isOnDevice == true)
    }

    /// Shown only when being offline actually changes something: sending is
    /// blocked, or an on-device model will answer without searching.
    static func offlineNotice(config: ProviderConfig?, isOnline: Bool) -> String? {
        guard !isOnline else { return nil }
        guard let config, config.kind.isOnDevice else { return "You're offline." }
        return config.webSearchMode == .off ? nil : "Web search is unavailable offline."
    }

    /// Replaces `range` in `text` with a newline and returns the new text and
    /// the cursor just after the newline. The range comes from SwiftUI's
    /// selection, which can hold indices that aren't valid in `text` (stale,
    /// out of bounds, or mid-character), so it's checked first; if it isn't
    /// valid the newline goes at the end.
    static func insertingNewline(in text: String, at range: Range<String.Index>?) -> (text: String, cursor: String.Index) {
        guard let range,
              let lower = String.Index(range.lowerBound, within: text),
              let upper = String.Index(range.upperBound, within: text),
              lower <= upper else {
            let result = text + "\n"
            return (result, result.endIndex)
        }
        let prefix = text[..<lower]
        let result = String(prefix) + "\n" + String(text[upper...])
        // Count in UTF-8 rather than characters: a newline after "\r" merges
        // into one "\r\n" character, so a character offset can overshoot.
        let cursor = result.utf8.index(result.startIndex, offsetBy: prefix.utf8.count + 1)
        return (result, cursor)
    }

    private func send(canSend: Bool) {
        guard canSend, !viewModel.isStreaming else { return }
        onSend()
    }
}

/// The multiline message field. Return sends; Shift-, Option- or
/// Control-Return adds a line. `onKeyPress` only sees hardware keyboards, so
/// the iPhone software keyboard's Return adds a line and the button sends.
private struct ComposerField: View {
    @Binding var text: String
    let onSend: () -> Void

    var body: some View {
        if #available(iOS 18, macOS 15, *) {
            SelectionField(text: $text, onSend: onSend)
        } else {
            // No selection binding before iOS 18 / macOS 15, so the newline
            // can only go at the end.
            Self.style(TextField("Message", text: $text, axis: .vertical), onSend: onSend) {
                text += "\n"
            }
        }
    }

    static func style(_ field: some View, onSend: @escaping () -> Void,
                      insertNewline: @escaping () -> Void) -> some View {
        field
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.isDisjoint(with: [.shift, .option, .control]) {
                    onSend()
                } else {
                    insertNewline()
                }
                return .handled
            }
    }

    /// Inserts the newline at the cursor, replacing any selected text.
    @available(iOS 18, macOS 15, *)
    private struct SelectionField: View {
        @Binding var text: String
        let onSend: () -> Void
        @State private var selection: TextSelection?

        var body: some View {
            ComposerField.style(
                TextField("Message", text: $text, selection: $selection, axis: .vertical),
                onSend: onSend,
                insertNewline: insertNewline
            )
        }

        private func insertNewline() {
            var range: Range<String.Index>?
            if case .selection(let selected) = selection?.indices { range = selected }
            let (newText, cursor) = ChatComposer.insertingNewline(in: text, at: range)
            text = newText
            selection = TextSelection(insertionPoint: cursor)
        }
    }
}
