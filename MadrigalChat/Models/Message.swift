import Foundation
import SwiftData

enum MessageRole: String, Codable, Sendable {
    case system, user, assistant
}

@Model
final class Message {
    var roleRaw: String = MessageRole.user.rawValue
    var content: String = ""
    /// A reasoning model's thinking. Display only; never sent back as context.
    var reasoning: String = ""
    var createdAt: Date = Date.now
    var modelID: String = ""          // which model produced this (assistant only)
    var isError: Bool = false
    var errorDescription: String = ""

    var conversation: Conversation? = nil

    @Relationship(deleteRule: .cascade, inverse: \Attachment.message)
    var attachments: [Attachment]? = []

    // Encoded `ToolPayload`: the web searches behind this reply, shown as
    // its sources. A plain string so new tool kinds never need a schema
    // migration. Empty string == no tool payload. See spec section 2.
    var toolPayloadJSON: String = ""

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    init(role: MessageRole, content: String) {
        self.roleRaw = role.rawValue
        self.content = content
    }
}
