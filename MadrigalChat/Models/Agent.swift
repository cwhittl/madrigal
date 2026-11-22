import Foundation
import SwiftData

/// A saved preset: a provider and model plus instructions and sampling
/// overrides. Picked in the same place as a raw model.
@Model
final class Agent {
    /// Stable identifier, stored on conversations and projects as a string.
    var stableID: UUID = UUID()
    var name: String = "New Agent"
    var iconSystemName: String = "sparkles"
    var colorHex: String = Palette.defaultHex

    var instructions: String = ""
    /// When true, the global instructions from Settings are left out.
    var replacesGlobalInstructions: Bool = false

    // Plain strings, like Conversation's, so the agent survives its
    // provider being deleted.
    var providerKeychainKey: String = ""
    var modelID: String = ""

    /// nil leaves it to the provider's own setting.
    var temperature: Double? = nil
    var maxTokens: Int? = nil

    var createdAt: Date = Date.now

    init(name: String = "New Agent") {
        self.name = name
    }

    var idString: String { stableID.uuidString }

    /// The provider's options with this agent's overrides applied on top.
    func generationOptions(over base: GenerationOptions) -> GenerationOptions {
        var options = base
        if let temperature { options.temperature = temperature }
        if let maxTokens { options.maxTokens = maxTokens }
        return options
    }

    /// The provider and model, for lists of agents.
    func subtitle(providers: [ProviderConfig]) -> String {
        guard let provider = providers.first(where: { $0.keychainKey == providerKeychainKey }) else {
            return "No provider"
        }
        return "\(provider.name) \u{00B7} \(modelID.isEmpty ? "Preferred model" : modelID)"
    }

    static func find(_ id: String, in agents: [Agent]) -> Agent? {
        guard !id.isEmpty else { return nil }
        return agents.first { $0.idString == id }
    }

    /// Fetches just the one agent, for callers without a `@Query` of them.
    static func find(_ id: String, in context: ModelContext) -> Agent? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        var descriptor = FetchDescriptor<Agent>(predicate: #Predicate { $0.stableID == uuid })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
