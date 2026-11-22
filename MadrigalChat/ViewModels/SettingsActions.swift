import Foundation
import SwiftData

/// Small helpers the settings screens share.
enum SettingsActions {

    static func makeProvider(from preset: ProviderPreset, context: ModelContext, existing: [ProviderConfig]) -> ProviderConfig {
        let config = ProviderConfig()
        preset.apply(to: config)
        config.isDefault = existing.isEmpty
        context.insert(config)
        return config
    }

    /// A new agent on the default provider, inserted into `context`.
    static func makeAgent(providers: [ProviderConfig], context: ModelContext) -> Agent {
        let agent = Agent()
        if let provider = providers.defaultProvider {
            agent.providerKeychainKey = provider.keychainKey
        }
        context.insert(agent)
        return agent
    }

    static func setDefault(_ config: ProviderConfig, among all: [ProviderConfig]) {
        for other in all { other.isDefault = (other.persistentModelID == config.persistentModelID) }
    }

    /// Deletes a provider and its Keychain item together, so a removed
    /// provider never leaves an orphaned secret behind.
    static func delete(_ config: ProviderConfig, from all: [ProviderConfig], context: ModelContext) {
        KeychainService.deleteOrLog(forKey: config.keychainKey)
        KeychainService.deleteOrLog(forKey: config.cfAccessKeychainKey)
        KeychainService.deleteOrLog(forKey: config.braveKeychainKey)
        let wasDefault = config.isDefault
        context.delete(config)
        if wasDefault, let next = all.first(where: { $0.persistentModelID != config.persistentModelID }) {
            next.isDefault = true
        }
    }

    /// Deletes everything. With CloudKit on, that includes every device on
    /// the same iCloud account, and the synced Keychain items with it.
    ///
    /// Call only once no view outside a `@Query` holds a model: post
    /// `.madrigalWillDeleteAllData` and let the UI tear down first (see
    /// `RootSplitView.requestDeleteAll`).
    @MainActor
    static func deleteAllData(context: ModelContext, providers: [ProviderConfig]) {
        for provider in providers {
            KeychainService.deleteOrLog(forKey: provider.keychainKey)
            KeychainService.deleteOrLog(forKey: provider.cfAccessKeychainKey)
            KeychainService.deleteOrLog(forKey: provider.braveKeychainKey)
        }
        // Deleted one by one rather than in a batch, so objects already
        // loaded are marked deleted and in-flight work sees `isLive == false`.
        deleteAll(Project.self, in: context)
        deleteAll(Conversation.self, in: context)
        deleteAll(Message.self, in: context)
        deleteAll(Attachment.self, in: context)
        deleteAll(ProjectFile.self, in: context)
        deleteAll(ProviderConfig.self, in: context)
        deleteAll(Agent.self, in: context)
        context.saveOrLog("delete all data")
        DeviceModelPreferences.shared.removeAll()
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) {
        for object in (try? context.fetch(FetchDescriptor<T>())) ?? [] where !object.isDeleted {
            context.delete(object)
        }
    }
}

extension Notification.Name {
    static let madrigalWillDeleteAllData = Notification.Name("dev.whittle.madrigalchat.willDeleteAllData")
}
