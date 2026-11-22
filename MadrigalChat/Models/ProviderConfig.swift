import Foundation
import SwiftData

/// What wire dialect and discovery behavior a provider config uses.
/// The first two speak the OpenAI chat-completions format on the wire and
/// differ in how the URL is built and how models are listed. Apple
/// Intelligence and local MLX models run on-device, using the network only
/// for web search when it's turned on.
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAICompatible
    case cloudflareWorkersAI
    case appleIntelligence
    case localMLX

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .cloudflareWorkersAI: return "Cloudflare Workers AI"
        case .appleIntelligence: return "Apple Intelligence"
        case .localMLX: return "On-device (MLX)"
        }
    }

    /// Cloudflare hands out "API tokens", everyone else says "API key".
    /// Matching their wording keeps people from pasting the wrong secret.
    /// The on-device kinds never ask for one.
    var secretFieldLabel: String {
        switch self {
        case .openAICompatible, .appleIntelligence, .localMLX: return "API Key"
        case .cloudflareWorkersAI: return "API Token"
        }
    }

    /// Runs without a network connection, apart from optional web search.
    var isOnDevice: Bool {
        self == .appleIntelligence || self == .localMLX
    }
}

extension Array where Element == ProviderConfig {
    /// The provider marked as default, else the first one.
    var defaultProvider: ProviderConfig? { first(where: \.isDefault) ?? first }
}

/// Non-secret provider config. The matching secret lives in the Keychain,
/// looked up by `keychainKey`. Nothing here is ever the secret itself.
@Model
final class ProviderConfig {
    var name: String = "OpenAI"
    var baseURL: String = "https://api.openai.com/v1"
    var keychainKey: String = UUID().uuidString   // stable ID, Keychain account
    var cachedModelIDs: [String] = []             // populated by "Fetch models"; unused for MLX, see `modelIDs`
    var isDefault: Bool = false
    var createdAt: Date = Date.now

    // Additive, defaulted properties: CloudKit-safe. Never make these
    // non-optional-without-default or sync silently fails to initialize.
    var kindRaw: String = ProviderKind.openAICompatible.rawValue
    var cloudflareAccountID: String = ""

    /// Cloudflare Access — added to every request as `CF-Access-Client-Id`.
    /// The matching `CF-Access-Client-Secret` is a secret, so it lives in the
    /// Keychain under `cfAccessKeychainKey`, never in this record.
    var cfAccessClientID: String = ""

    /// Last model chosen for this provider, used as the default for new chats.
    /// Synced, so for MLX it's only read as a fallback; see `defaultModelID`.
    var preferredModelID: String = ""

    /// Whether this provider requires an API key/token. When false, the secret
    /// field is hidden and no warning is shown for missing keys.
    var apiKeyRequired: Bool = true

    /// `ProviderPreset.id` this config was created from. Empty for configs
    /// saved before this existed; see `ProviderPreset.resolve(for:)`.
    var presetID: String = ""

    /// Sent as `temperature` when set. nil leaves it to the provider.
    var temperature: Double? = nil

    /// Sent as `max_tokens` (`max_completion_tokens` for OpenAI) when set.
    var maxTokens: Int? = nil

    /// Character budget for one request's context. 0 means
    /// `ContextAssembler.totalCharacterCap`.
    var contextCharacterLimit: Int = 0

    /// Model used for project chat summaries. Empty means the chat's model.
    /// Synced, so for MLX it's only read as a fallback; see `summaryModel`.
    var summaryModelID: String = ""

    /// `WebSearchMode` raw value. On-device kinds only.
    var webSearchModeRaw: String = WebSearchMode.off.rawValue

    /// `WebSearchBackend` raw value. Empty for configs saved before there
    /// was a choice; see `webSearchBackend`.
    var webSearchBackendRaw: String = ""

    /// Base URL of the user's SearXNG server, used when the backend is
    /// `.searxng`.
    var searxngURL: String = ""

    init(name: String = "OpenAI", baseURL: String = "https://api.openai.com/v1") {
        self.name = name
        self.baseURL = baseURL
    }

    var preset: ProviderPreset { ProviderPreset.resolve(for: self) }

    /// Keychain account for the Cloudflare Access client secret.
    var cfAccessKeychainKey: String { "\(keychainKey).cfaccess" }

    /// Keychain account for the Brave Search API key, used when the web
    /// search backend is `.brave`.
    var braveKeychainKey: String { BraveSearchClient.keychainKey(for: keychainKey) }

    var generationOptions: GenerationOptions {
        GenerationOptions(temperature: temperature, maxTokens: maxTokens)
    }

    /// Makes a hand-typed model ID the preferred one, adding it to the
    /// list so pickers show it.
    func useManualModel(_ model: String) {
        preferredModelID = model
        if !cachedModelIDs.contains(model) {
            cachedModelIDs.append(model)
        }
    }

    var effectiveContextLimit: Int {
        contextCharacterLimit > 0 ? contextCharacterLimit : ContextAssembler.totalCharacterCap
    }

    /// Whether a missing secret should be flagged. Only Custom lets the user
    /// opt out; every other preset knows whether its service needs one.
    var needsSecret: Bool {
        preset.isCustom ? apiKeyRequired : preset.requiresSecret
    }

    var webSearchMode: WebSearchMode {
        get { WebSearchMode(rawValue: webSearchModeRaw) ?? .off }
        set { webSearchModeRaw = newValue.rawValue }
    }

    /// On device unless chosen otherwise. A config saved before the choice
    /// existed keeps using its SearXNG server if it had one, so its queries
    /// don't quietly start going somewhere else.
    var webSearchBackend: WebSearchBackend {
        get {
            WebSearchBackend(rawValue: webSearchBackendRaw)
                ?? (searxngURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .onDevice : .searxng)
        }
        set { webSearchBackendRaw = newValue.rawValue }
    }

    /// Hosted providers have their own search features, if any.
    var supportsWebSearch: Bool { kind.isOnDevice }

    /// Why web search can't run with these settings, or nil when it can or
    /// is off.
    var webSearchProblem: String? {
        guard supportsWebSearch, webSearchMode != .off, webSearchBackend == .searxng else { return nil }
        let trimmed = searxngURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter your SearXNG server's URL." }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil,
              SearXNGClient.searchURL(base: trimmed, query: "") != nil else {
            return "The SearXNG URL doesn't look like a URL."
        }
        return Self.plainHTTPProblem(url)
    }

    var kind: ProviderKind {
        get { ProviderKind(rawValue: kindRaw) ?? .openAICompatible }
        set { kindRaw = newValue.rawValue }
    }

    /// The URL actually used for requests. For Cloudflare this is derived
    /// from the account ID rather than typed by the user.
    var resolvedBaseURL: String {
        switch kind {
        case .cloudflareWorkersAI:
            return CloudflareWorkersAIProvider.baseURL(forAccount: cloudflareAccountID)
        case .openAICompatible:
            return baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        case .appleIntelligence, .localMLX:
            return ""
        }
    }

    /// What the settings list shows under the provider name. Never the secret.
    @MainActor
    var subtitle: String {
        switch kind {
        case .cloudflareWorkersAI:
            return cloudflareAccountID.isBlank
                ? "No account ID set"
                : "Account \(cloudflareAccountID.prefix(8))\u{2026}"
        case .openAICompatible:
            return baseURL
        case .appleIntelligence:
            return "On-device"
        case .localMLX:
            // This device's downloads.
            let count = modelIDs.count
            return "On-device \u{00B7} \(count) model\(count == 1 ? "" : "s")"
        }
    }

    // MARK: - Models

    /// MLX models downloaded on this device. The screenshot demo has no
    /// downloads, so it shows the synced list instead.
    @MainActor
    var installedLocalModelIDs: [String] {
        #if DEBUG
        if ScreenshotDemo.isActive { return cachedModelIDs }
        #endif
        return LocalModelStore.shared.installedIDs
    }

    /// Models the pickers offer. For MLX, what's downloaded on this device.
    @MainActor
    var modelIDs: [String] {
        kind == .localMLX ? installedLocalModelIDs : cachedModelIDs
    }

    /// The model new chats start with. For MLX it's this device's own
    /// choice, never synced: this device's preference if it's still
    /// downloaded, else the synced `preferredModelID` if that's downloaded
    /// here (configs from before the choice went per device), else the
    /// first download.
    @MainActor
    var defaultModelID: String {
        get { defaultModelID(installed: modelIDs) }
        set { setDefaultModelID(newValue) }
    }

    @MainActor
    func defaultModelID(installed: [String], device: DeviceModelPreferences = .shared) -> String {
        guard kind == .localMLX else { return preferredModelID }
        if let own = device.preferredModel(for: keychainKey), installed.contains(own) { return own }
        if installed.contains(preferredModelID) { return preferredModelID }
        return installed.first ?? ""
    }

    @MainActor
    func setDefaultModelID(_ model: String, device: DeviceModelPreferences = .shared) {
        if kind == .localMLX {
            device.setPreferredModel(model, for: keychainKey)
        } else {
            preferredModelID = model
        }
    }

    /// Model for project chat summaries; empty means the chat's model. For
    /// MLX it's this device's choice, and empty when that isn't downloaded.
    @MainActor
    var summaryModel: String {
        get { summaryModel(installed: modelIDs) }
        set { setSummaryModel(newValue) }
    }

    @MainActor
    func summaryModel(installed: [String], device: DeviceModelPreferences = .shared) -> String {
        guard kind == .localMLX else { return summaryModelID }
        if let own = device.summaryModel(for: keychainKey) {
            return installed.contains(own) ? own : ""
        }
        return installed.contains(summaryModelID) ? summaryModelID : ""
    }

    @MainActor
    func setSummaryModel(_ model: String, device: DeviceModelPreferences = .shared) {
        if kind == .localMLX {
            device.setSummaryModel(model, for: keychainKey)
        } else {
            summaryModelID = model
        }
    }

    /// Whether this config has everything it needs apart from the secret.
    var configurationProblem: String? {
        switch kind {
        case .cloudflareWorkersAI:
            if cloudflareAccountID.isBlank { return "Account ID is required." }
            if !CloudflareWorkersAIProvider.isValidAccountID(cloudflareAccountID) {
                return "Account ID should be 32 hexadecimal characters."
            }
            return nil
        case .appleIntelligence:
            return AppleIntelligence.unavailableReason
        case .localMLX:
            return LocalMLX.unavailableReason
        case .openAICompatible:
            let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Base URL is required." }
            guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
                return "Base URL doesn't look like a URL."
            }
            if trimmed.hasSuffix("/chat/completions") {
                return "Use the base URL only, without /chat/completions."
            }
            return Self.plainHTTPProblem(url)
        }
    }

    /// App Transport Security blocks plain HTTP to the internet, so it only
    /// works for local network hosts.
    nonisolated static func plainHTTPProblem(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "http", !isLocalNetworkHost(url.host ?? "") else { return nil }
        return "Plain http:// only works for local network addresses. Use https://."
    }

    /// Hosts App Transport Security lets through over plain HTTP with
    /// `NSAllowsLocalNetworking`: localhost, `.local` names, unqualified
    /// names, and IP literals.
    nonisolated static func isLocalNetworkHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return true }
        if host.contains(":") { return true }   // IPv6 literal
        return host.allSatisfy { $0.isNumber || $0 == "." }
    }
}
