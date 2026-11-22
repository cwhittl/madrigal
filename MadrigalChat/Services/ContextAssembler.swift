import Foundation

/// Builds the outgoing message array for a request. See spec section 7.
///
/// The rules here are deliberately crude and predictable: character counts,
/// not tokens. Token-accurate counting is out of scope for v1.
enum ContextAssembler {

    static let knowledgeCharacterCap = 50_000
    static let otherChatsCharacterCap = 15_000
    static let totalCharacterCap = 100_000

    /// Shares of the request budget that knowledge and other-chat summaries
    /// may take, so a small on-device context isn't filled before history.
    static let knowledgeShare = 0.5
    static let otherChatsShare = 0.15

    /// Everything that isn't chat history goes into one system message.
    /// Gemma, some Mistral templates, and several local servers reject a
    /// second system message, so the parts are joined rather than sent apart.
    static func build(
        for conversation: Conversation,
        globalInstructions: String = "",
        agent: Agent? = nil,
        characterCap: Int = totalCharacterCap
    ) -> [OutgoingMessage] {
        let characterCap = max(0, characterCap)
        var parts: [String] = []

        if agent?.replacesGlobalInstructions != true {
            let global = globalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !global.isEmpty { parts.append(global) }
        }

        if let agent {
            let instructions = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !instructions.isEmpty { parts.append(instructions) }
        }

        if let project = conversation.project {
            let instructions = project.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !instructions.isEmpty { parts.append(instructions) }
            let knowledgeCap = min(knowledgeCharacterCap, Int(Double(characterCap) * knowledgeShare))
            if let knowledge = knowledgeBlock(for: project, cap: knowledgeCap) { parts.append(knowledge) }
            let othersCap = min(otherChatsCharacterCap, Int(Double(characterCap) * otherChatsShare))
            if project.shareChatSummaries,
               let others = otherChatsBlock(for: project, excluding: conversation, cap: othersCap) {
                parts.append(others)
            }
        }

        let system = parts.isEmpty
            ? []
            : [OutgoingMessage(role: .system, content: parts.joined(separator: "\n\n"))]

        let history: [OutgoingMessage] = conversation.sendableMessages
            .map { OutgoingMessage(role: $0.role, content: $0.content) }

        return trim(system: system, history: history, cap: characterCap)
    }

    /// Concatenates a project's knowledge files, each delimited, capped in total.
    static func knowledgeBlock(for project: Project, cap: Int = knowledgeCharacterCap) -> String? {
        let files = project.files
        guard !files.isEmpty else { return nil }

        var block = ""
        // String.count walks the whole string, so keep a running total.
        var used = 0
        var truncated = false

        for file in files {
            let header = "--- Knowledge file: \(file.filename) ---\n"
            let footer = "\n--- End file ---\n\n"
            let remaining = cap - used - header.count - footer.count

            if remaining <= 0 {
                truncated = true
                break
            }

            var text = file.extractedText
            var textCount = text.count
            if textCount > remaining {
                text = String(text.prefix(remaining))
                textCount = remaining
                truncated = true
            }
            block += header + text + footer
            used += header.count + textCount + footer.count
        }

        guard !block.isEmpty else { return nil }
        if truncated {
            block += "[additional files omitted - see Project settings]"
        }
        return block
    }

    /// Summaries of the project's other chats, most recent first, capped in total.
    static func otherChatsBlock(
        for project: Project,
        excluding conversation: Conversation,
        cap: Int = otherChatsCharacterCap
    ) -> String? {
        let others = project.sortedConversations.filter {
            $0.stableID != conversation.stableID && !$0.summary.isEmpty
        }
        guard !others.isEmpty else { return nil }

        let intro = "Summaries of other chats in this project, for background only. The user may refer to them.\n\n"
        var block = intro
        // String.count walks the whole string, so keep a running total.
        var used = intro.count
        var truncated = false

        for other in others {
            let date = other.updatedAt.formatted(date: .abbreviated, time: .omitted)
            let entry = "--- Other chat in this project: \"\(other.title)\" (\(date)) ---\n\(other.summary)\n\n"
            let entryCount = entry.count
            if used + entryCount > cap {
                truncated = true
                break
            }
            block += entry
            used += entryCount
        }

        guard block != intro else { return nil }
        if truncated {
            block += "[older chats omitted]"
        }
        return block
    }

    /// Drops the oldest non-system messages until the whole payload fits.
    /// System messages are never dropped: they carry the project's rules.
    /// If they alone still don't fit beside the latest message, their text
    /// is cut from the end as a last resort.
    static func trim(
        system: [OutgoingMessage],
        history: [OutgoingMessage],
        cap: Int = totalCharacterCap
    ) -> [OutgoingMessage] {
        let counts = history.map(\.content.count)
        let systemCounts = system.map(\.content.count)
        let systemTotal = systemCounts.reduce(0, +)
        var total = systemTotal + counts.reduce(0, +)
        var dropped = 0
        while total > cap && history.count - dropped > 1 {
            total -= counts[dropped]
            dropped += 1
        }
        guard total > cap, systemTotal > 0 else {
            return system + history.dropFirst(dropped)
        }

        // Even the latest message alone doesn't fit beside the system text.
        var room = max(0, cap - (total - systemTotal))
        var cutSystem: [OutgoingMessage] = []
        for (message, count) in zip(system, systemCounts) where room > 0 {
            let text = count > room ? String(message.content.prefix(room)) : message.content
            room -= min(count, room)
            cutSystem.append(OutgoingMessage(role: message.role, content: text))
        }
        return cutSystem + history.dropFirst(dropped)
    }
}
