import Foundation
import SwiftData

/// Remembers which chats have a reply in flight, so one that never ended
/// can be marked as interrupted on the next launch. That happens when iOS
/// ends the app while an on-device reply is paused in the background, or
/// when the app is quit or crashes mid-reply. Without this the partial
/// text would look like a finished reply.
///
/// Kept in UserDefaults, per device: only this device's replies can be cut
/// off by this device's app ending.
struct InterruptedReplies {
    static let defaultsKey = "inFlightReplies"
    static let message = "Madrigal was closed before this reply finished. Retry to start it again."

    /// Uses its own suite while hosting tests, so they never touch the
    /// app's real list.
    @MainActor static let shared = InterruptedReplies(
        defaults: AppConfig.isHostingTests ? UserDefaults(suiteName: "InterruptedRepliesTests") ?? .standard : .standard
    )

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var ids: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.defaultsKey) ?? []) }
        nonmutating set { defaults.set(Array(newValue).sorted(), forKey: Self.defaultsKey) }
    }

    func begin(_ conversationID: UUID) {
        ids.insert(conversationID.uuidString)
    }

    func end(_ conversationID: UUID) {
        ids.remove(conversationID.uuidString)
    }

    /// Chats whose reply was still in flight when the app last ended, and
    /// forgets them. Call once per launch, before any reply starts.
    func takeLeftovers() -> [UUID] {
        let leftovers = ids.compactMap(UUID.init(uuidString:))
        ids = []
        return leftovers
    }

    @MainActor private static var recovered = false

    /// Marks the unfinished reply in each leftover chat as interrupted,
    /// keeping its text, and withdraws any "paused" notification for it.
    /// Runs once per launch: a second window opening later must not mark
    /// a reply the first one is streaming.
    @MainActor
    func recoverOnce(in context: ModelContext, notifier: ReplyNotifier) {
        guard !Self.recovered else { return }
        Self.recovered = true
        recover(in: context, notifier: notifier)
    }

    @MainActor
    func recover(in context: ModelContext, notifier: ReplyNotifier) {
        let leftovers = takeLeftovers()
        guard !leftovers.isEmpty else { return }
        for id in leftovers {
            notifier.replyResumed(conversationID: id)
            var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.stableID == id })
            descriptor.fetchLimit = 1
            guard let conversation = try? context.fetch(descriptor).first else { continue }
            Self.markInterrupted(in: conversation, context: context)
        }
        context.saveOrLog("marking interrupted replies")
    }

    /// The last message is the unfinished reply, or the user's message if
    /// no reply text was saved; either way the chat ends with an error the
    /// user can retry.
    @MainActor
    static func markInterrupted(in conversation: Conversation, context: ModelContext) {
        if let last = conversation.orderedMessages.last, last.role == .assistant {
            guard !last.isError else { return }
            last.isError = true
            last.errorDescription = message
        } else if conversation.orderedMessages.last?.role == .user {
            let reply = Message(role: .assistant, content: "")
            context.insert(reply)
            reply.conversation = conversation
            reply.isError = true
            reply.errorDescription = message
        }
    }
}
