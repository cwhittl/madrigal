import Foundation
import SwiftData

/// Writes a short summary of a project chat so the project's other chats
/// can see what it covered. Best-effort: any failure keeps the old summary.
enum ConversationSummarizer {

    static let transcriptCharacterCap = 20_000
    static let summaryCharacterCap = 1_000

    private static let prompt = """
        Summarize this conversation in at most 5 short bullet points: topics \
        covered, decisions made, open questions, and facts the user stated \
        about themselves or their work. No preamble.
        """

    @MainActor
    static func summarize(
        _ conversation: Conversation,
        provider: ChatProvider,
        model: String,
        context: ModelContext
    ) async {
        let messages = conversation.sendableMessages
        guard !messages.isEmpty else { return }
        let count = messages.count

        var transcript = messages
            .map { "\($0.role.rawValue.capitalized): \($0.content)" }
            .joined(separator: "\n\n")
        if transcript.count > transcriptCharacterCap {
            // Keep the most recent part: it's what the chat is about now.
            transcript = String(transcript.suffix(transcriptCharacterCap))
        }

        var latest = StreamSnapshot()
        do {
            let deltas = provider.streamCompletion(
                messages: [
                    OutgoingMessage(role: .system, content: prompt),
                    OutgoingMessage(role: .user, content: transcript),
                ],
                model: model,
                options: GenerationOptions(yieldsToOtherModels: true)
            )
            // Nobody watches a summary being written, so only the final
            // snapshot matters; accumulate off the main actor.
            for try await snapshot in StreamAccumulator.snapshots(of: deltas, every: .seconds(1)) {
                latest = snapshot
            }
        } catch {
            return
        }

        let summary = latest.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            .truncated(to: summaryCharacterCap)
        guard !summary.isEmpty else { return }

        // The chat may have been deleted while the summary was being written.
        guard conversation.isLive else { return }

        // No touch(): a background summary shouldn't reorder the sidebar.
        conversation.summary = summary
        conversation.summarizedMessageCount = count
        context.saveOrLog("chat summary")
    }
}
