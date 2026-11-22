import Foundation
import SwiftData

@Model
final class Project {
    var name: String = "New Project"
    var iconSystemName: String = "folder"
    var colorHex: String = Palette.defaultHex
    var customInstructions: String = ""
    /// Whether chats in this project receive summaries of the other chats.
    var shareChatSummaries: Bool = true
    /// `Agent.stableID` new chats in this project start with. Empty for none.
    var defaultAgentID: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \Conversation.project)
    var conversations: [Conversation]? = []

    @Relationship(deleteRule: .cascade, inverse: \ProjectFile.project)
    var knowledgeFiles: [ProjectFile]? = []

    init(name: String = "New Project") {
        self.name = name
    }

    var sortedConversations: [Conversation] {
        (conversations ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    var files: [ProjectFile] {
        (knowledgeFiles ?? []).sorted { $0.addedAt < $1.addedAt }
    }

    /// The name to show. New projects start blank (and may sync to other
    /// devices before they're named).
    var displayName: String { name.isBlank ? "Untitled Project" : name }

    func touch() { updatedAt = .now }
}
