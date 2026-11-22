import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Renders a conversation as Markdown for copying, sharing, and export.
/// Errors are left out; reasoning is left out too, since it's display-only.
enum ConversationExporter {

    static func markdown(for conversation: Conversation) -> String {
        var lines = ["# \(conversation.title)", ""]
        if let project = conversation.project {
            lines.append("_Project: \(project.displayName)_")
            lines.append("")
        }
        for message in conversation.sendableMessages {
            switch message.role {
            case .user:
                lines.append("## You")
            case .assistant:
                lines.append(message.modelID.isEmpty ? "## Assistant" : "## Assistant (\(message.modelID))")
            case .system:
                continue
            }
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// A filesystem-safe name for the exported file, without the extension.
    static func filename(for conversation: Conversation) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = conversation.title
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Chat" : String(cleaned.prefix(80))
    }
}

/// A chat for `ShareLink`, rendered only when the user actually shares.
/// Building the Markdown in `body` would read every message, so the view
/// would re-render on each save while a reply streams.
struct ConversationMarkdownExport: Transferable {
    let filename: String
    /// A main-actor closure is Sendable even though it captures the
    /// non-Sendable model, so the conversation never leaves the main actor.
    private let render: @MainActor @Sendable () -> String

    @MainActor
    init(_ conversation: Conversation) {
        self.filename = ConversationExporter.filename(for: conversation)
        self.render = { ConversationExporter.markdown(for: conversation) }
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { export in
            let markdown = await export.render()
            return Data(markdown.utf8)
        }
        .suggestedFileName { $0.filename + ".md" }
    }
}

/// A Markdown file for `.fileExporter`.
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [markdownType] }
    static let markdownType = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
