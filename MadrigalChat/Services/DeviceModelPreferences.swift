import Foundation
import Observation
import SwiftData

/// On-device MLX model choices that belong to this device only: the
/// preferred and summary model per provider, and the model picked in each
/// chat. Each device downloads its own models, so syncing these through
/// CloudKit would have devices with different downloads overwrite each
/// other's choices.
///
/// `@Observable`, unlike plain UserDefaults reads, so views redraw when a
/// choice changes.
@Observable
@MainActor
final class DeviceModelPreferences {
    static let preferredKey = "deviceModels.preferred"
    static let summaryKey = "deviceModels.summary"
    static let chatModelKey = "deviceModels.chat"

    /// Uses its own suite while hosting tests, so they never touch the
    /// app's real choices.
    static let shared = DeviceModelPreferences(
        defaults: AppConfig.isHostingTests ? UserDefaults(suiteName: "DeviceModelPreferencesTests") ?? .standard : .standard
    )

    @ObservationIgnored let defaults: UserDefaults

    /// Preferred model by `ProviderConfig.keychainKey`.
    private(set) var preferred: [String: String]
    /// Summary model by `ProviderConfig.keychainKey`. Empty means the chat's,
    /// and is stored rather than removed so it overrides the synced value.
    private(set) var summary: [String: String]
    /// This device's pick by `Conversation.stableID`.
    private(set) var chatModels: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferred = Self.read(Self.preferredKey, from: defaults)
        summary = Self.read(Self.summaryKey, from: defaults)
        chatModels = Self.read(Self.chatModelKey, from: defaults)
    }

    func preferredModel(for providerKey: String) -> String? { preferred[providerKey] }

    func setPreferredModel(_ model: String, for providerKey: String) {
        preferred[providerKey] = model.isEmpty ? nil : model
        defaults.set(preferred, forKey: Self.preferredKey)
    }

    func summaryModel(for providerKey: String) -> String? { summary[providerKey] }

    func setSummaryModel(_ model: String, for providerKey: String) {
        summary[providerKey] = model
        defaults.set(summary, forKey: Self.summaryKey)
    }

    func chatModel(for conversationID: UUID) -> String? { chatModels[conversationID.uuidString] }

    func setChatModel(_ model: String, for conversationID: UUID) {
        chatModels[conversationID.uuidString] = model.isEmpty ? nil : model
        defaults.set(chatModels, forKey: Self.chatModelKey)
    }

    /// Call when a chat is deleted, so entries don't pile up.
    func removeChatModel(for conversationID: UUID) {
        guard chatModels[conversationID.uuidString] != nil else { return }
        chatModels[conversationID.uuidString] = nil
        defaults.set(chatModels, forKey: Self.chatModelKey)
    }

    /// Drops picks for chats that no longer exist, such as ones deleted on
    /// another device. An empty store is left alone: it's more likely still
    /// downloading from iCloud than actually empty, and pruning then would
    /// throw away every pick.
    func pruneChatModels(keeping existing: Set<UUID>) {
        guard !existing.isEmpty else { return }
        let kept = chatModels.filter { key, _ in UUID(uuidString: key).map(existing.contains) ?? false }
        guard kept.count != chatModels.count else { return }
        chatModels = kept
        defaults.set(chatModels, forKey: Self.chatModelKey)
    }

    private var pruned = false

    /// Prunes once per launch, so a second window doesn't repeat it.
    func pruneChatModelsOnce(in context: ModelContext) {
        guard !pruned else { return }
        pruned = true
        guard !chatModels.isEmpty else { return }
        var descriptor = FetchDescriptor<Conversation>()
        descriptor.propertiesToFetch = [\.stableID]
        guard let conversations = try? context.fetch(descriptor) else { return }
        pruneChatModels(keeping: Set(conversations.map(\.stableID)))
    }

    func removeAll() {
        preferred = [:]
        summary = [:]
        chatModels = [:]
        for key in [Self.preferredKey, Self.summaryKey, Self.chatModelKey] {
            defaults.removeObject(forKey: key)
        }
    }

    private static func read(_ key: String, from defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
