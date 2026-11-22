import Foundation
import SwiftData
import Testing
@testable import Madrigal

/// On-device MLX model choices stay on each device; other kinds keep using
/// the synced fields.
@MainActor
struct DeviceModelPreferencesTests {
    let container: ModelContainer
    let device: DeviceModelPreferences
    var context: ModelContext { container.mainContext }

    static let small = "mlx-community/Qwen3-1.7B-4bit"
    static let medium = "mlx-community/Qwen3-4B-4bit"
    static let large = "mlx-community/Qwen3-8B-4bit"

    init() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: MadrigalSchemaV1.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let suite = "DeviceModelPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        device = DeviceModelPreferences(defaults: defaults)
    }

    private func mlx() -> ProviderConfig {
        let config = ProviderConfig(name: "On-device", baseURL: "")
        config.kind = .localMLX
        context.insert(config)
        return config
    }

    private func chat(with config: ProviderConfig) -> Conversation {
        let conversation = Conversation()
        conversation.providerKeychainKey = config.keychainKey
        context.insert(conversation)
        return conversation
    }

    // MARK: - Store

    @Test func choicesPersistAcrossInstances() throws {
        let id = UUID()
        device.setPreferredModel(Self.small, for: "p")
        device.setSummaryModel("", for: "p")
        device.setChatModel(Self.large, for: id)

        let reloaded = DeviceModelPreferences(defaults: device.defaults)
        #expect(reloaded.preferredModel(for: "p") == Self.small)
        #expect(reloaded.summaryModel(for: "p") == "")
        #expect(reloaded.chatModel(for: id) == Self.large)

        reloaded.removeChatModel(for: id)
        #expect(DeviceModelPreferences(defaults: device.defaults).chatModel(for: id) == nil)
    }

    @Test func pruneDropsPicksForMissingChats() {
        let kept = UUID(), gone = UUID()
        device.setChatModel(Self.small, for: kept)
        device.setChatModel(Self.medium, for: gone)

        device.pruneChatModels(keeping: [kept, UUID()])
        #expect(device.chatModel(for: kept) == Self.small)
        #expect(device.chatModel(for: gone) == nil)
        #expect(DeviceModelPreferences(defaults: device.defaults).chatModel(for: gone) == nil)
    }

    @Test func pruneLeavesPicksAloneWhenNoChatsExist() {
        let id = UUID()
        device.setChatModel(Self.small, for: id)
        device.pruneChatModels(keeping: [])
        #expect(device.chatModel(for: id) == Self.small)
    }

    @Test func pruneOnceReadsChatsFromTheStore() {
        let config = mlx()
        let conversation = chat(with: config)
        let gone = UUID()
        device.setChatModel(Self.small, for: conversation.stableID)
        device.setChatModel(Self.medium, for: gone)

        device.pruneChatModelsOnce(in: context)
        #expect(device.chatModel(for: conversation.stableID) == Self.small)
        #expect(device.chatModel(for: gone) == nil)
    }

    // MARK: - Provider defaults

    @Test func mlxDefaultUsesLegacySyncedValueWhenInstalled() {
        let config = mlx()
        config.preferredModelID = Self.medium
        #expect(config.defaultModelID(installed: [Self.small, Self.medium], device: device) == Self.medium)
    }

    @Test func mlxDefaultFallsBackToFirstInstalled() {
        let config = mlx()
        config.preferredModelID = Self.large
        #expect(config.defaultModelID(installed: [Self.small, Self.medium], device: device) == Self.small)
        #expect(config.defaultModelID(installed: [], device: device) == "")
    }

    @Test func mlxDefaultPrefersThisDevicesChoice() {
        let config = mlx()
        config.preferredModelID = Self.small
        config.setDefaultModelID(Self.medium, device: device)
        #expect(config.preferredModelID == Self.small)
        #expect(config.defaultModelID(installed: [Self.small, Self.medium], device: device) == Self.medium)
        // Deleted here since: the legacy value takes over again.
        #expect(config.defaultModelID(installed: [Self.small], device: device) == Self.small)
    }

    @Test func mlxSummaryModelIsPerDevice() {
        let config = mlx()
        config.summaryModelID = Self.small
        #expect(config.summaryModel(installed: [Self.small], device: device) == Self.small)
        #expect(config.summaryModel(installed: [Self.medium], device: device) == "")

        config.setSummaryModel(Self.medium, device: device)
        #expect(config.summaryModelID == Self.small)
        #expect(config.summaryModel(installed: [Self.small, Self.medium], device: device) == Self.medium)
        #expect(config.summaryModel(installed: [Self.small], device: device) == "")

        // "Same as chat" overrides the synced value rather than falling back to it.
        config.setSummaryModel("", device: device)
        #expect(config.summaryModel(installed: [Self.small, Self.medium], device: device) == "")
    }

    // MARK: - Chat model

    @Test func mlxChosenModelOrder() {
        let config = mlx()
        config.setDefaultModelID(Self.small, device: device)
        let conversation = chat(with: config)
        let all = [Self.small, Self.medium, Self.large]

        // Nothing chosen: this device's default.
        #expect(conversation.chosenModel(config: config, installed: all, device: device) == Self.small)

        // Synced model, used where it's installed.
        conversation.modelID = Self.medium
        #expect(conversation.chosenModel(config: config, installed: all, device: device) == Self.medium)
        #expect(conversation.chosenModel(config: config, installed: [Self.small, Self.large], device: device) == Self.small)

        // This device's pick wins, where it's installed.
        device.setChatModel(Self.large, for: conversation.stableID)
        #expect(conversation.chosenModel(config: config, installed: all, device: device) == Self.large)
        #expect(conversation.chosenModel(config: config, installed: [Self.small, Self.medium], device: device) == Self.medium)
        #expect(conversation.chosenModel(config: config, installed: [Self.small], device: device) == Self.small)

        // An agent set on another device overrides this device's pick.
        conversation.agentID = UUID().uuidString
        #expect(conversation.chosenModel(config: config, installed: all, device: device) == Self.medium)
    }

    @Test func mlxApplyModelStaysOnThisDevice() {
        let config = mlx()
        config.preferredModelID = Self.small
        let conversation = chat(with: config)
        conversation.modelID = Self.small
        conversation.agentID = UUID().uuidString

        conversation.apply(model: Self.large, config: config, device: device)

        #expect(conversation.modelID == Self.small)
        #expect(config.preferredModelID == Self.small)
        #expect(conversation.agentID.isEmpty)
        #expect(device.chatModel(for: conversation.stableID) == Self.large)
        #expect(device.preferredModel(for: config.keychainKey) == Self.large)
        #expect(conversation.chosenModel(config: config, installed: [Self.small, Self.large], device: device) == Self.large)
    }

    @Test func applyingAnAgentDropsThisDevicesPick() {
        let config = mlx()
        let conversation = chat(with: config)
        device.setChatModel(Self.large, for: conversation.stableID)
        let agent = Agent()
        agent.providerKeychainKey = config.keychainKey
        agent.modelID = Self.small
        context.insert(agent)

        conversation.apply(agent, providers: [config], device: device)

        #expect(conversation.agentID == agent.idString)
        #expect(conversation.modelID == Self.small)
        #expect(device.chatModel(for: conversation.stableID) == nil)
    }

    @Test func deletingAChatDropsThisDevicesPick() {
        let conversation = chat(with: mlx())
        let id = conversation.stableID
        device.setChatModel(Self.large, for: id)

        conversation.delete(from: context, device: device)

        #expect(device.chatModel(for: id) == nil)
    }

    @Test func newChatOnMLXLeavesModelEmpty() {
        let config = mlx()
        config.isDefault = true
        config.preferredModelID = Self.small
        let conversation = Conversation.create(in: nil, providers: [config], context: context)
        #expect(conversation.providerKeychainKey == config.keychainKey)
        #expect(conversation.modelID.isEmpty)
    }

    // MARK: - Other kinds

    @Test func otherKindsKeepUsingSyncedFields() {
        let config = ProviderConfig(name: "Hosted")
        context.insert(config)
        config.cachedModelIDs = ["a", "b"]
        config.preferredModelID = "b"
        config.summaryModelID = "a"

        #expect(config.modelIDs == ["a", "b"])
        #expect(config.defaultModelID(installed: config.modelIDs, device: device) == "b")
        #expect(config.summaryModel(installed: config.modelIDs, device: device) == "a")

        config.setDefaultModelID("a", device: device)
        #expect(config.preferredModelID == "a")
        #expect(device.preferredModel(for: config.keychainKey) == nil)

        let conversation = chat(with: config)
        #expect(conversation.chosenModel(config: config, installed: config.modelIDs, device: device) == "a")
        conversation.apply(model: "b", config: config, device: device)
        #expect(conversation.modelID == "b")
        #expect(config.preferredModelID == "b")
        #expect(device.chatModel(for: conversation.stableID) == nil)
    }
}
