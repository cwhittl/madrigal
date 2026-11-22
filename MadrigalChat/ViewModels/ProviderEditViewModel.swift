import Foundation
import Observation

/// Drives the provider editor: secret entry, model fetching, validation.
@Observable
@MainActor
final class ProviderEditViewModel {

    var secretDraft: String = ""
    /// Cloudflare Access client secret, kept in the Keychain like the key.
    var cfAccessSecretDraft: String = ""
    /// Brave Search API key, for web search. Also kept in the Keychain.
    var braveKeyDraft: String = ""
    /// What the secure field shows when a secret already exists. Cached so
    /// `body` doesn't run SecItemCopyMatching on every render.
    private(set) var storedSecretMask: String?
    private(set) var hasStoredCFAccessSecret: Bool = false
    private(set) var hasStoredBraveKey: Bool = false
    private(set) var isFetchingModels: Bool = false
    private(set) var fetchStatus: String?
    private(set) var fetchFailed: Bool = false
    private(set) var saveError: String?

    func refreshSecretState(for config: ProviderConfig) {
        storedSecretMask = KeychainService.maskedValue(forKey: config.keychainKey)
        hasStoredCFAccessSecret = KeychainService.hasKey(forKey: config.cfAccessKeychainKey)
        hasStoredBraveKey = KeychainService.hasKey(forKey: config.braveKeychainKey)
    }

    var hasStoredSecret: Bool { storedSecretMask != nil }

    /// Writes the secrets only if the user typed new ones. An untouched
    /// field must never clear an existing key.
    func commitSecretIfNeeded(for config: ProviderConfig) {
        commit(&secretDraft, forKey: config.keychainKey, config: config)
        commit(&cfAccessSecretDraft, forKey: config.cfAccessKeychainKey, config: config)
        commit(&braveKeyDraft, forKey: config.braveKeychainKey, config: config)
    }

    private func commit(_ draft: inout String, forKey key: String, config: ProviderConfig) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainService.save(apiKey: trimmed, forKey: key)
            draft = ""
            saveError = nil
            refreshSecretState(for: config)
        } catch {
            saveError = error.localizedDescription
        }
    }

    func clearCFAccessSecret(for config: ProviderConfig) {
        KeychainService.deleteOrLog(forKey: config.cfAccessKeychainKey)
        cfAccessSecretDraft = ""
        refreshSecretState(for: config)
    }

    func clearBraveKey(for config: ProviderConfig) {
        KeychainService.deleteOrLog(forKey: config.braveKeychainKey)
        braveKeyDraft = ""
        refreshSecretState(for: config)
    }

    func clearSecret(for config: ProviderConfig) {
        KeychainService.deleteOrLog(forKey: config.keychainKey)
        secretDraft = ""
        refreshSecretState(for: config)
    }

    func fetchModels(for config: ProviderConfig) async {
        commitSecretIfNeeded(for: config)

        if let problem = config.configurationProblem {
            fetchFailed = true
            fetchStatus = problem
            return
        }

        isFetchingModels = true
        fetchFailed = false
        fetchStatus = nil
        defer { isFetchingModels = false }

        do {
            let provider = try await ProviderFactory.recipe(for: config).makeProvider()
            let models = try await provider.fetchAvailableModels()
            // MLX lists this device's downloads straight from the store;
            // writing them here would sync them to every other device.
            if config.kind != .localMLX {
                config.cachedModelIDs = models
                if config.preferredModelID.isEmpty {
                    config.preferredModelID = models.first ?? ""
                }
            }
            fetchStatus = models.isEmpty
                ? "No models returned. You can still type a model ID."
                : "Found \(models.count) model\(models.count == 1 ? "" : "s")."
        } catch {
            fetchFailed = true

            // Model discovery must never block provider setup. On Cloudflare
            // we can still offer a usable starting list; everywhere else the
            // model field stays free-text.
            if config.kind == .cloudflareWorkersAI, config.cachedModelIDs.isEmpty {
                config.cachedModelIDs = CloudflareWorkersAIProvider.fallbackModelIDs
                fetchStatus = "Couldn't reach Cloudflare's model list (\(short(error))). Showing known model IDs instead."
            } else {
                fetchStatus = "Couldn't fetch models (\(short(error))). You can still type a model ID."
            }
        }
    }

    private func short(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.truncated(to: 120)
    }
}
