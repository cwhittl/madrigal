import Foundation
import SwiftData
import Testing
@testable import Madrigal

@MainActor
struct ValidationTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: MadrigalSchemaV1.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func provider(_ presetID: String) -> ProviderConfig {
        let preset = ProviderPreset.all.first { $0.id == presetID }!
        let config = ProviderConfig()
        preset.apply(to: config)
        context.insert(config)
        return config
    }

    // MARK: - Project

    @Test func projectNeedsANonBlankName() {
        let project = Project()
        #expect(project.isValid)
        project.name = ""
        #expect(!project.isValid)
        project.name = "  \n "
        #expect(project.validationIssues == ["Name is required."])
        project.name = " Work "
        #expect(project.isValid)
    }

    // MARK: - Agent

    @Test func agentNeedsANameAndAnExistingProvider() {
        let openAI = provider("openai")
        let agent = Agent()
        agent.providerKeychainKey = openAI.keychainKey
        #expect(agent.isValid(providers: [openAI]))

        agent.name = "   "
        #expect(agent.validationIssues(providers: [openAI]) == ["Name is required."])
    }

    @Test func agentWithNoProvidersAsksForOneFirst() {
        let agent = Agent()
        #expect(agent.validationIssues(providers: []) == ["Add a provider first."])
    }

    @Test func agentWhoseProviderWasDeletedIsInvalid() {
        let openAI = provider("openai")
        let other = provider("groq")
        let agent = Agent()
        agent.providerKeychainKey = openAI.keychainKey
        #expect(agent.validationIssues(providers: [other]) == ["Choose a provider."])

        agent.providerKeychainKey = ""
        #expect(!agent.isValid(providers: [openAI, other]))
    }

    // MARK: - Provider

    @Test func providerNeedsANonBlankName() {
        let config = provider("openai")
        config.name = " "
        #expect(config.validationIssues(hasSecret: true) == ["Name is required."])
    }

    @Test func hostedProviderNeedsASecret() {
        let config = provider("openai")
        #expect(config.validationIssues(hasSecret: false) == ["API Key is required."])
        #expect(config.isValid(hasSecret: true))
    }

    @Test func hostedProviderIgnoresItsFixedBaseURL() {
        let config = provider("openai")
        config.baseURL = ""
        #expect(config.isValid(hasSecret: true))
    }

    @Test func cloudflareNeedsAnAccountIDAndToken() {
        let config = provider("cloudflare")
        #expect(config.validationIssues(hasSecret: false) == ["Account ID is required.", "API Token is required."])
        config.cloudflareAccountID = "  "
        #expect(!config.isValid(hasSecret: true))
        config.cloudflareAccountID = "0123456789abcdef0123456789abcdef"
        #expect(config.isValid(hasSecret: true))
    }

    @Test func localServerNeedsAWebBaseURLButNoSecret() {
        let config = provider("ollama")
        #expect(config.isValid(hasSecret: false))

        config.baseURL = "   "
        #expect(config.validationIssues(hasSecret: false) == ["Base URL is required."])
        config.baseURL = "localhost:11434"
        #expect(!config.isValid(hasSecret: false))
        config.baseURL = "ftp://example.com"
        #expect(!config.isValid(hasSecret: false))
        config.baseURL = "http:///v1"
        #expect(!config.isValid(hasSecret: false))
        config.baseURL = " http://192.168.1.10:11434/v1 "
        #expect(config.isValid(hasSecret: false))
    }

    @Test func customProviderSecretFollowsItsToggle() {
        let config = provider("custom")
        config.baseURL = "https://llm.example.com/v1"
        #expect(config.validationIssues(hasSecret: false) == ["API Key is required."])
        config.apiKeyRequired = false
        #expect(config.isValid(hasSecret: false))
    }

    @Test func customProviderNeedsABaseURL() {
        let config = provider("custom")
        #expect(config.validationIssues(hasSecret: true) == ["Base URL is required."])
    }

    @Test func onDeviceProviderNeedsNoSecret() {
        #expect(provider("mlx").isValid(hasSecret: false))
        #expect(provider("apple").isValid(hasSecret: false))
    }

    @Test func searXNGBackendNeedsAWebURL() {
        let config = provider("mlx")
        config.webSearchMode = .always
        config.webSearchBackend = .searxng
        #expect(config.validationIssues(hasSecret: false) == ["SearXNG URL is required."])
        config.searxngURL = "search.example.com"
        #expect(!config.isValid(hasSecret: false))
        config.searxngURL = "https://search.example.com"
        #expect(config.isValid(hasSecret: false))
    }

    @Test func searXNGURLIsIgnoredWhenNotUsed() {
        let config = provider("mlx")
        config.webSearchBackend = .searxng
        config.searxngURL = "nonsense"
        #expect(config.isValid(hasSecret: false))   // search is off

        config.webSearchMode = .auto
        config.webSearchBackend = .onDevice
        #expect(config.isValid(hasSecret: false))
    }

    // MARK: - Conversation

    @Test func conversationIsDisposableUntilAMessageIsSent() {
        let conversation = Conversation()
        context.insert(conversation)
        #expect(conversation.isDisposable)

        let message = Message(role: .user, content: "hi")
        context.insert(message)
        message.conversation = conversation
        #expect(!conversation.isDisposable)
    }
}
