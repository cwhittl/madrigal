import Foundation
import SwiftData

@Model
final class Conversation {
    /// Stable identifier for SwiftUI view identity. Unlike `persistentModelID`,
    /// this UUID never changes after the object is created, which prevents
    /// views keyed on it from being destroyed when SwiftData assigns a
    /// permanent identifier after initial insertion.
    var stableID: UUID = UUID()
    var title: String = Conversation.defaultTitle
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var pinned: Bool = false

    var project: Project? = nil

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message]? = []

    // Which provider/model this conversation currently targets.
    // Stored as plain strings (not a relationship to ProviderConfig) so the
    // conversation still displays correctly if the ProviderConfig is deleted.
    var providerLabel: String = ""
    var modelID: String = ""

    // Keychain key of the ProviderConfig this conversation was last sent with.
    // Used to re-resolve the provider without holding a CloudKit relationship.
    var providerKeychainKey: String = ""

    /// `Agent.stableID` this chat uses, or empty for a raw model. A string,
    /// not a relationship, so deleting the agent leaves the chat intact.
    var agentID: String = ""

    /// Short model-written summary, shared with the project's other chats.
    var summary: String = ""
    /// How many sendable messages existed when `summary` was written.
    var summarizedMessageCount: Int = 0

    init(title: String = Conversation.defaultTitle) {
        self.title = title
    }

    /// A chat's title until `autoTitleIfNeeded` names it.
    static let defaultTitle = "New Chat"

    /// Messages in chronological order. SwiftData to-many relationships are
    /// unordered, so never rely on the raw array's order.
    var orderedMessages: [Message] {
        (messages ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    /// Messages that are actually sent as context: no errors, no empties.
    var sendableMessages: [Message] {
        orderedMessages.filter { !$0.isError && !$0.content.isEmpty }
    }

    /// True when this chat is in a project and has changed since its last summary.
    var needsSummary: Bool {
        project != nil && sendableMessages.count != summarizedMessageCount
    }

    /// Inserts a new chat. It starts with the project's default agent if
    /// that still exists, else the default provider and its preferred model.
    /// An MLX provider's model is left empty, so each device uses its own.
    @MainActor
    @discardableResult
    static func create(
        in project: Project?,
        providers: [ProviderConfig],
        agents: [Agent] = [],
        context: ModelContext
    ) -> Conversation {
        let conversation = Conversation()
        conversation.project = project
        if let agent = Agent.find(project?.defaultAgentID ?? "", in: agents) {
            conversation.apply(agent, providers: providers)
        } else if let provider = providers.defaultProvider {
            conversation.providerLabel = provider.name
            conversation.providerKeychainKey = provider.keychainKey
            conversation.modelID = provider.kind == .localMLX ? "" : provider.defaultModelID
        }
        context.insert(conversation)
        return conversation
    }

    /// Points this chat at an agent and its provider and model. If the
    /// agent's provider is gone, the default provider is used instead.
    /// The agent's model syncs on purpose: every device that has it uses it.
    @MainActor
    func apply(_ agent: Agent, providers: [ProviderConfig], device: DeviceModelPreferences = .shared) {
        agentID = agent.idString
        let own = providers.first { $0.keychainKey == agent.providerKeychainKey }
        let provider = own ?? providers.defaultProvider
        providerLabel = provider?.name ?? ""
        providerKeychainKey = provider?.keychainKey ?? ""
        // Another provider's model ID rarely works on the fallback, so it
        // gets the fallback's preferred model instead. An MLX fallback's is
        // left empty, so each device uses its own.
        if own != nil && !agent.modelID.isEmpty {
            modelID = agent.modelID
        } else if let provider, provider.kind != .localMLX {
            modelID = provider.defaultModelID
        } else {
            modelID = ""
        }
        device.removeChatModel(for: stableID)
    }

    /// Deletes this chat along with this device's model pick for it. Use
    /// this rather than `context.delete` so the pick doesn't linger.
    @MainActor
    func delete(from context: ModelContext, device: DeviceModelPreferences = .shared) {
        forgetDeviceModel(device: device)
        context.delete(self)
    }

    /// Drops this device's model pick, for when the chat is deleted some
    /// other way, such as by its project's cascade.
    @MainActor
    func forgetDeviceModel(device: DeviceModelPreferences = .shared) {
        device.removeChatModel(for: stableID)
    }

    /// Points this chat at a raw model, dropping any agent, and makes it
    /// the provider's preferred model. An MLX pick stays on this device:
    /// the synced `modelID` is left alone.
    @MainActor
    func apply(model: String, config: ProviderConfig, device: DeviceModelPreferences = .shared) {
        agentID = ""
        providerLabel = config.name
        providerKeychainKey = config.keychainKey
        if config.kind == .localMLX {
            device.setChatModel(model, for: stableID)
        } else {
            modelID = model
        }
        config.setDefaultModelID(model, device: device)
    }

    /// The provider this chat uses: the one it was last sent with, else
    /// the default, else the first.
    func resolveConfig(among configs: [ProviderConfig]) -> ProviderConfig? {
        if !providerKeychainKey.isEmpty,
           let match = configs.first(where: { $0.keychainKey == providerKeychainKey }) {
            return match
        }
        return configs.defaultProvider
    }

    /// The model to send to `config`: the chat's own, else the provider's
    /// preferred one, else its first. Empty when there's none.
    ///
    /// For MLX, the first of these that's downloaded on this device: this
    /// device's own pick for the chat (unless an agent has taken over since),
    /// the synced `modelID` (an agent's, or another device's from before
    /// picks stayed per device), then this device's default. Falling back
    /// never changes the synced `modelID`.
    @MainActor
    func chosenModel(config: ProviderConfig) -> String {
        chosenModel(config: config, installed: config.modelIDs)
    }

    @MainActor
    func chosenModel(config: ProviderConfig, installed: [String], device: DeviceModelPreferences = .shared) -> String {
        guard config.kind == .localMLX else {
            if !modelID.isEmpty { return modelID }
            let preferred = config.defaultModelID(installed: installed, device: device)
            return preferred.isEmpty ? installed.first ?? "" : preferred
        }
        if agentID.isEmpty, let own = device.chatModel(for: stableID), installed.contains(own) { return own }
        if installed.contains(modelID) { return modelID }
        return config.defaultModelID(installed: installed, device: device)
    }

    var lastUserMessage: Message? {
        orderedMessages.last { $0.role == .user }
    }

    func agent(in agents: [Agent]) -> Agent? {
        Agent.find(agentID, in: agents)
    }

    /// The agent's name if this chat uses one, else the model it sends
    /// to `config` on this device, else the stored model ID.
    @MainActor
    func displayModelName(agents: [Agent], config: ProviderConfig? = nil) -> String {
        agent(in: agents)?.name ?? config.map { chosenModel(config: $0) } ?? modelID
    }

    /// A chat matching a sidebar search, with an excerpt of its first
    /// matching message unless the title matched.
    struct SearchHit: Identifiable {
        let conversation: Conversation
        let excerpt: String?
        var id: PersistentIdentifier { conversation.persistentModelID }
    }

    /// Case- and diacritic-insensitive match on titles and message text.
    /// Messages are matched by the store, so only the matching ones load,
    /// instead of every message of every chat. `conversations` sets the
    /// order of the results.
    static func search(
        _ query: String,
        in conversations: [Conversation],
        context: ModelContext
    ) -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.content.localizedStandardContains(query) },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let messages = (try? context.fetch(descriptor)) ?? []

        // The earliest matching message per chat.
        var firstMatch: [PersistentIdentifier: Message] = [:]
        for message in messages {
            guard let id = message.conversation?.persistentModelID, firstMatch[id] == nil else { continue }
            firstMatch[id] = message
        }

        return conversations.compactMap { conversation in
            if conversation.title.localizedStandardContains(query) {
                return SearchHit(conversation: conversation, excerpt: nil)
            }
            guard let message = firstMatch[conversation.persistentModelID] else { return nil }
            return SearchHit(
                conversation: conversation,
                excerpt: SearchExcerpt.make(from: message.content, around: query)
            )
        }
    }

    func touch() {
        updatedAt = .now
        project?.touch()
    }

    /// Derives a title from the first user message, once, so the sidebar
    /// stops saying "New Chat" after the first exchange.
    func autoTitleIfNeeded() {
        guard title == Self.defaultTitle else { return }
        guard let first = orderedMessages.first(where: { $0.role == .user }) else { return }
        let trimmed = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        title = firstLine.truncated(to: 60)
    }
}
