import Foundation

/// Everyone off this device that the app sends data to. Each case needs a
/// point in `DataDisclosure` that names it, which `DataDisclosureTests`
/// checks, so adding a case means updating what users are told.
enum DataRecipient: CaseIterable, Sendable {
    /// The hosted or self-run provider a chat is sent to.
    case chatProvider
    /// On-device model lookups and downloads.
    case huggingFace
    /// The user's SearXNG server, for web search.
    case searxng
    /// DuckDuckGo, for web search from the device.
    case duckDuckGo
    /// Wikipedia, for web search from the device.
    case wikipedia
    /// Brave's Search API, for web search with the user's key.
    case braveSearch
    /// The sites behind the top search results, opened to read them.
    case resultPages
    /// Open-Meteo, for forecasts when a search asks about the weather.
    case openMeteo
    /// The user's private iCloud database, when sync is on.
    case iCloud

    /// Words the covering point must use, so it actually says who.
    var disclosedName: String {
        switch self {
        case .chatProvider: return "provider"
        case .huggingFace: return "Hugging Face"
        case .searxng: return "SearXNG"
        case .duckDuckGo: return "DuckDuckGo"
        case .wikipedia: return "Wikipedia"
        case .braveSearch: return "Brave"
        case .resultPages: return "websites"
        case .openMeteo: return "Open-Meteo"
        case .iCloud: return "iCloud"
        }
    }
}

extension ProviderKind {
    /// Where a chat goes when sent with this kind, or nil when replies are
    /// generated on this device. No `default`, so a new kind won't compile
    /// until it's placed here and the disclosure is checked against it.
    var chatRecipient: DataRecipient? {
        switch self {
        case .openAICompatible, .cloudflareWorkersAI: return .chatProvider
        case .appleIntelligence, .localMLX: return nil
        }
    }
}

/// The text of the "Your Data" screen, kept out of the view so tests can
/// check it against the code it describes.
enum DataDisclosure {
    struct Point: Identifiable {
        let symbol: String
        let title: String
        let text: String
        /// Who this point tells the user about.
        var recipients: Set<DataRecipient> = []

        var id: String { title }
    }

    /// Preset names given as examples of hosted providers.
    static let hostedExamples = ["OpenAI", "Anthropic", "OpenRouter"]

    /// The kinds the text calls on-device: Apple Intelligence and downloaded models.
    static let onDeviceKinds = Set(ProviderKind.allCases.filter(\.isOnDevice))

    static let intro = "Madrigal has no servers of its own. It sends your requests straight to the AI providers you add, using your own keys, or runs models right on your device."

    static func points(cloudSync: Bool = AppConfig.enableCloudKitSync) -> [Point] {
        let examples = hostedExamples.dropLast().joined(separator: ", ") + ", or " + hostedExamples.last!
        return [
            Point(
                symbol: "paperplane",
                title: "What is sent",
                text: "Each time you send a message, the chat so far goes to the provider you picked for it, along with your custom instructions and the instructions of any agent you chose. In projects, that also includes the project's instructions, the text of its knowledge files, and summaries of its other chats.",
                recipients: [.chatProvider]
            ),
            Point(
                symbol: "building.2",
                title: "Who receives it",
                text: "Only the provider configured for that chat, such as \(examples), or a server you run yourself. Their own privacy policy and terms decide how they store and use it. With Apple Intelligence or a downloaded on-device model, replies are generated on this device and your chat isn't sent to any provider.",
                recipients: [.chatProvider]
            ),
            Point(
                symbol: "arrow.down.circle",
                title: "Model downloads",
                text: "Looking up or downloading an on-device model contacts Hugging Face, which sees the model's name and your IP address but none of your chats. Downloaded models stay on this device and aren't synced or backed up.",
                recipients: [.huggingFace]
            ),
            Point(
                symbol: "magnifyingglass",
                title: "Web search",
                text: "If you turn on web search for an on-device model, search queries go straight from this device to DuckDuckGo and Wikipedia, or, if you choose, to Brave's Search API with your own key, or to a SearXNG server you set up, which passes them on to the search engines it uses. To answer from the results rather than just their links, the device then opens the top few result pages, so those websites see your IP address too, and questions about the weather somewhere also send the place name to Open-Meteo for a forecast. A query is either your message, up to its first \(WebSearchConfig.queryCharacterLimit) characters, or words the model picks from it. Whoever receives a query sees it and your IP address; the rest of the chat stays on this device.",
                recipients: [.searxng, .duckDuckGo, .wikipedia, .braveSearch, .resultPages, .openMeteo]
            ),
            Point(
                symbol: "icloud",
                title: "What stays with you",
                text: cloudSync
                    ? "Chats and projects are stored on your devices and in your private iCloud database. API keys stay in your iCloud Keychain. The developer can't see any of it."
                    : "Chats, projects, and API keys stay on this device. The developer can't see any of it.",
                recipients: cloudSync ? [.iCloud] : []
            )
        ]
    }
}
