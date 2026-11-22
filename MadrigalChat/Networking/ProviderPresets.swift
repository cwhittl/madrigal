import Foundation

/// Prefill options in the "Add Provider" flow. Presets only fill in the name,
/// URL, and kind - the user always supplies their own secret.
struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let kind: ProviderKind
    /// Shown under the secret field to explain what to paste.
    let secretHint: String
    /// Whether the edit screen shows the base URL. Hosted services have a
    /// fixed URL; only local servers and custom endpoints need to change it.
    var editsBaseURL: Bool = false
    /// Whether the service always needs a key. Ignored for Custom, where the
    /// user decides with the "Requires API Key" toggle.
    var requiresSecret: Bool = true
    /// Shown under the base URL field, for presets that edit it.
    var baseURLHint: String = "The base URL only, without /chat/completions."
    /// Starting `contextCharacterLimit` for models with a small window. 0
    /// leaves the default.
    var contextCharacterLimit: Int = 0

    var isCustom: Bool { id == "custom" }

    static let custom = ProviderPreset(
        id: "custom",
        name: "Custom",
        baseURL: "",
        kind: .openAICompatible,
        secretHint: "Whatever key the endpoint expects as a bearer token, if any. Leave this blank if the endpoint doesn't require one — for example, if it's only protected by Cloudflare Access.",
        editsBaseURL: true
    )

    static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            kind: .openAICompatible,
            secretHint: "A key from platform.openai.com, starting with sk-."
        ),
        ProviderPreset(
            id: "anthropic",
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            kind: .openAICompatible,
            secretHint: "A key from platform.claude.com/settings/keys, starting with sk-ant-."
        ),
        ProviderPreset(
            id: "openrouter",
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            kind: .openAICompatible,
            secretHint: "A key from openrouter.ai/keys."
        ),
        ProviderPreset(
            id: "xai",
            name: "xAI (Grok)",
            baseURL: "https://api.x.ai/v1",
            kind: .openAICompatible,
            secretHint: "A key from console.x.ai, starting with xai-."
        ),
        ProviderPreset(
            id: "groq",
            name: "Groq",
            baseURL: "https://api.groq.com/openai/v1",
            kind: .openAICompatible,
            secretHint: "A key from console.groq.com, starting with gsk_. Groq is not Grok — for xAI's Grok, use the xAI preset."
        ),
        ProviderPreset(
            id: "cloudflare",
            name: "Cloudflare Workers AI",
            baseURL: "",
            kind: .cloudflareWorkersAI,
            secretHint: "A Cloudflare API token with the Workers AI Read permission. Not your Global API Key."
        ),
        ProviderPreset(
            id: "gemini",
            name: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            kind: .openAICompatible,
            secretHint: "A key from aistudio.google.com/apikey."
        ),
        ProviderPreset(
            id: "mistral",
            name: "Mistral",
            baseURL: "https://api.mistral.ai/v1",
            kind: .openAICompatible,
            secretHint: "A key from console.mistral.ai/api-keys."
        ),
        ProviderPreset(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            kind: .openAICompatible,
            secretHint: "A key from platform.deepseek.com/api_keys, starting with sk-."
        ),
        ProviderPreset(
            id: "together",
            name: "Together AI",
            baseURL: "https://api.together.xyz/v1",
            kind: .openAICompatible,
            secretHint: "A key from api.together.ai/settings/api-keys."
        ),
        ProviderPreset(
            id: "apple",
            name: "Apple Intelligence (on-device)",
            baseURL: "",
            kind: .appleIntelligence,
            secretHint: "",
            requiresSecret: false,
            contextCharacterLimit: AppleIntelligence.defaultContextCharacterLimit
        ),
        ProviderPreset(
            id: "mlx",
            name: "On-device models (MLX)",
            baseURL: "",
            kind: .localMLX,
            secretHint: "",
            requiresSecret: false,
            contextCharacterLimit: LocalMLX.defaultContextCharacterLimit
        ),
        ProviderPreset(
            id: "lmstudio",
            name: "LM Studio (local)",
            baseURL: "http://localhost:1234/v1",
            kind: .openAICompatible,
            secretHint: "",
            editsBaseURL: true,
            requiresSecret: false,
            baseURLHint: localServerHint(port: 1234, setting: "Serve on Local Network in LM Studio's server settings")
        ),
        ProviderPreset(
            id: "ollama",
            name: "Ollama (local)",
            baseURL: "http://localhost:11434/v1",
            kind: .openAICompatible,
            secretHint: "",
            editsBaseURL: true,
            requiresSecret: false,
            baseURLHint: localServerHint(port: 11434, setting: "OLLAMA_HOST=0.0.0.0 on the computer running Ollama")
        ),
        custom
    ]

    /// What the "Add Provider" list offers. Apple Intelligence is hidden on
    /// devices and systems that can't run it, but stays in `all` so a config synced from
    /// a newer device still resolves to its own preset.
    static var selectable: [ProviderPreset] {
        all.filter { $0.kind != .appleIntelligence || AppleIntelligence.isSupported }
    }

    /// On iPhone and iPad, localhost is the device itself, so local servers
    /// need the computer's LAN address.
    private static func localServerHint(port: Int, setting: String) -> String {
        #if os(iOS)
        return "On iPhone and iPad, localhost means this device. Use your computer's local IP address instead, for example http://192.168.1.20:\(port)/v1, and set \(setting)."
        #else
        return "The base URL only, without /chat/completions. To use this server from an iPhone or iPad, set \(setting)."
        #endif
    }

    /// The preset a config was created from. Configs saved before `presetID`
    /// existed are matched on kind and base URL; anything that doesn't match
    /// cleanly, or uses Cloudflare Access, is treated as Custom so no setting
    /// in use gets hidden.
    static func resolve(for config: ProviderConfig) -> ProviderPreset {
        if let match = all.first(where: { $0.id == config.presetID }) { return match }
        // One preset per kind, apart from OpenAI-compatible.
        if config.kind != .openAICompatible {
            return all.first { $0.kind == config.kind } ?? custom
        }
        if !config.cfAccessClientID.isEmpty { return custom }
        let url = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { !$0.baseURL.isEmpty && $0.baseURL == url } ?? custom
    }

    func apply(to config: ProviderConfig) {
        config.presetID = id
        config.name = name
        config.baseURL = baseURL
        config.kind = kind
        config.apiKeyRequired = requiresSecret
        if contextCharacterLimit > 0 {
            config.contextCharacterLimit = contextCharacterLimit
        }
        if kind == .appleIntelligence {
            // There's only one model, so there's nothing to fetch first.
            config.cachedModelIDs = [AppleIntelligence.modelID]
            config.preferredModelID = AppleIntelligence.modelID
        }
    }
}

enum ProviderFactory {
    /// What a live provider needs, copied from `config`, with the checks
    /// that don't need the Keychain done up front. Build it with
    /// `ProviderRecipe.makeProvider()`, which reads the secrets off the
    /// main actor at call time, so they're never held in a model object.
    ///
    /// The secret is optional for OpenAI-compatible endpoints: some are only
    /// gated by something like Cloudflare Access (see `cfAccessClientID` and
    /// `cfAccessKeychainKey` on `ProviderConfig`) and take no bearer token
    /// at all. Cloudflare Workers AI is the one exception - its account API
    /// always requires an API token, so that case still enforces it.
    static func recipe(for config: ProviderConfig) throws -> ProviderRecipe {
        let kind: ProviderRecipe.Kind
        switch config.kind {
        case .openAICompatible:
            kind = .openAICompatible(baseURL: config.resolvedBaseURL)
        case .cloudflareWorkersAI:
            guard !config.cloudflareAccountID.isBlank else {
                throw ChatProviderError.missingAccountID
            }
            kind = .cloudflareWorkersAI(accountID: config.cloudflareAccountID)
        case .appleIntelligence:
            // On-device, so no secrets to read.
            if let reason = AppleIntelligence.unavailableReason {
                throw ChatProviderError.unavailable(reason: reason)
            }
            kind = .appleIntelligence
        case .localMLX:
            // Also on-device. Whether the chat's model is downloaded on this
            // device is checked when it streams, since that's per model.
            if let reason = LocalMLX.unavailableReason {
                throw ChatProviderError.unavailable(reason: reason)
            }
            kind = .localMLX
        }
        return ProviderRecipe(
            kind: kind,
            keychainKey: config.keychainKey,
            cfAccessClientID: config.cfAccessClientID,
            cfAccessKeychainKey: config.cfAccessKeychainKey
        )
    }

    /// What a request needs to search, or nil when search is off or the
    /// settings aren't usable (see `ProviderConfig.webSearchProblem`).
    static func makeWebSearch(for config: ProviderConfig) -> WebSearchConfig? {
        guard config.supportsWebSearch, config.webSearchMode != .off, config.webSearchProblem == nil else { return nil }
        let client: any WebSearchClient = switch config.webSearchBackend {
        case .onDevice: OnDeviceSearchClient()
        case .brave: BraveSearchClient { [braveKeychainKey = config.braveKeychainKey] in
            (try? KeychainService.loadAPIKey(forKey: braveKeychainKey)) ?? nil
        }
        case .searxng: SearXNGClient(baseURL: config.searxngURL.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let isApple = config.kind == .appleIntelligence
        var search = WebSearchConfig(
            mode: config.webSearchMode,
            client: client,
            characterCap: isApple ? WebSearchConfig.appleCharacterCap : WebSearchConfig.mlxCharacterCap
        )
        search.pageReader = WebPageReader()
        search.pagesToRead = isApple ? WebSearchConfig.applePagesToRead : WebSearchConfig.mlxPagesToRead
        search.weather = OpenMeteoWeather()
        return search
    }

}

/// A provider's settings, copied out of its `ProviderConfig` so the
/// provider can be built away from the main actor: the Keychain reads in
/// `build()` block.
struct ProviderRecipe: Sendable {
    enum Kind: Sendable {
        case openAICompatible(baseURL: String)
        case cloudflareWorkersAI(accountID: String)
        case appleIntelligence
        case localMLX
    }

    let kind: Kind
    let keychainKey: String
    let cfAccessClientID: String
    let cfAccessKeychainKey: String

    /// Builds the provider off the main actor.
    @concurrent
    func makeProvider() async throws -> ChatProvider {
        try build()
    }

    /// Builds the provider, reading its secrets from the Keychain.
    private func build() throws -> ChatProvider {
        switch kind {
        case .openAICompatible(let baseURL):
            return OpenAICompatibleProvider(
                baseURL: baseURL,
                apiKey: try Self.secret(forKey: keychainKey),
                cfAccessClientID: cfAccessClientID,
                cfAccessClientSecret: try Self.secret(forKey: cfAccessKeychainKey)
            )

        case .cloudflareWorkersAI(let accountID):
            let token = try Self.secret(forKey: keychainKey)
            guard !token.isEmpty else {
                throw ChatProviderError.missingAPIKey
            }
            return CloudflareWorkersAIProvider(
                accountID: accountID,
                apiToken: token,
                cfAccessClientID: cfAccessClientID,
                cfAccessClientSecret: try Self.secret(forKey: cfAccessKeychainKey)
            )

        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(iOS 26, macOS 26, *) {
                return AppleIntelligenceProvider()
            }
            #endif
            throw ChatProviderError.unavailable(reason: "Apple Intelligence isn't supported here.")

        case .localMLX:
            #if !targetEnvironment(simulator) && arch(arm64)
            return LocalMLXProvider()
            #else
            throw ChatProviderError.unavailable(reason: "On-device models aren't supported here.")
            #endif
        }
    }

    private static func secret(forKey key: String) throws -> String {
        try KeychainService.loadAPIKey(forKey: key) ?? ""
    }
}
