import Foundation
import SwiftData
import Testing
@testable import Madrigal

@MainActor
struct ContextAssemblerTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: MadrigalSchemaV1.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func message(_ role: MessageRole, _ text: String, in conversation: Conversation, at offset: TimeInterval) -> Message {
        let message = Message(role: role, content: text)
        message.createdAt = Date(timeIntervalSince1970: 1_000 + offset)
        context.insert(message)
        message.conversation = conversation
        return message
    }

    // MARK: - trim

    @Test func trimDropsOldestHistoryFirst() {
        let system = [OutgoingMessage(role: .system, content: String(repeating: "s", count: 10))]
        let history = (0..<5).map { OutgoingMessage(role: .user, content: "\($0)" + String(repeating: "x", count: 9)) }
        let kept = ContextAssembler.trim(system: system, history: history, cap: 35)
        #expect(kept.map(\.content.first) == ["s", "3", "4"])
    }

    @Test func trimAlwaysKeepsTheLatestMessage() {
        let history = [OutgoingMessage(role: .user, content: String(repeating: "x", count: 100))]
        #expect(ContextAssembler.trim(system: [], history: history, cap: 10).count == 1)
    }

    // MARK: - build

    @Test func plainChatHasNoSystemMessage() {
        let conversation = Conversation()
        context.insert(conversation)
        _ = message(.user, "hi", in: conversation, at: 0)

        let outgoing = ContextAssembler.build(for: conversation)
        #expect(outgoing.map(\.role) == [.user])
    }

    @Test func everythingButHistoryIsOneSystemMessage() {
        let project = Project(name: "P")
        project.customInstructions = "Project rules."
        context.insert(project)
        let file = ProjectFile(filename: "notes.txt", extractedText: "Facts.")
        context.insert(file)
        file.project = project

        let other = Conversation(title: "Earlier")
        other.summary = "- talked about X"
        context.insert(other)
        other.project = project

        let conversation = Conversation()
        context.insert(conversation)
        conversation.project = project
        _ = message(.user, "question", in: conversation, at: 0)
        _ = message(.assistant, "answer", in: conversation, at: 1)
        let failed = message(.assistant, "", in: conversation, at: 2)
        failed.isError = true
        _ = message(.user, "follow-up", in: conversation, at: 3)

        let outgoing = ContextAssembler.build(for: conversation, globalInstructions: "  Be brief.  ")

        #expect(outgoing.map(\.role) == [.system, .user, .assistant, .user])
        let system = outgoing[0].content
        #expect(system.hasPrefix("Be brief.\n\nProject rules."))
        #expect(system.contains("--- Knowledge file: notes.txt ---\nFacts."))
        #expect(system.contains("talked about X"))
        #expect(outgoing.last?.content == "follow-up")
    }

    @Test func knowledgeBlockIsCapped() {
        let project = Project()
        context.insert(project)
        for index in 0..<3 {
            let file = ProjectFile(
                filename: "f\(index).txt",
                extractedText: String(repeating: "k", count: ContextAssembler.knowledgeCharacterCap / 2)
            )
            file.addedAt = Date(timeIntervalSince1970: TimeInterval(index))
            context.insert(file)
            file.project = project
        }

        let block = try! #require(ContextAssembler.knowledgeBlock(for: project))
        #expect(block.contains("f0.txt"))
        #expect(!block.contains("f2.txt"))
        #expect(block.hasSuffix("[additional files omitted - see Project settings]"))
    }

    @Test func smallBudgetScalesKnowledgeAndSummaries() {
        let project = Project()
        project.shareChatSummaries = true
        context.insert(project)
        let file = ProjectFile(filename: "big.txt", extractedText: String(repeating: "k", count: 30_000))
        context.insert(file)
        file.project = project

        let other = Conversation(title: "Earlier")
        other.summary = String(repeating: "s", count: 5_000)
        context.insert(other)
        other.project = project

        let conversation = Conversation()
        context.insert(conversation)
        conversation.project = project
        _ = message(.user, "question", in: conversation, at: 0)

        let cap = 8_000
        let outgoing = ContextAssembler.build(for: conversation, characterCap: cap)
        #expect(outgoing.map(\.role) == [.system, .user])
        #expect(outgoing.reduce(0) { $0 + $1.content.count } <= cap)
        #expect(outgoing[0].content.contains("--- Knowledge file: big.txt ---"))
        #expect(outgoing.last?.content == "question")
    }

    @Test func negativeBudgetStillSendsTheLatestMessage() {
        let project = Project()
        project.customInstructions = "Rules."
        context.insert(project)
        let conversation = Conversation()
        context.insert(conversation)
        conversation.project = project
        _ = message(.user, "question", in: conversation, at: 0)

        let outgoing = ContextAssembler.build(for: conversation, characterCap: -500)
        #expect(outgoing.map(\.role) == [.user])
        #expect(outgoing.last?.content == "question")
    }

    @Test func trimCutsSystemTextAsLastResort() {
        let system = [OutgoingMessage(role: .system, content: String(repeating: "s", count: 100))]
        let history = [
            OutgoingMessage(role: .user, content: String(repeating: "a", count: 10)),
            OutgoingMessage(role: .user, content: String(repeating: "b", count: 10)),
        ]
        let kept = ContextAssembler.trim(system: system, history: history, cap: 40)
        #expect(kept.count == 2)
        #expect(kept[0].content.count == 30)
        #expect(kept[1].content.first == "b")
    }

    @Test func otherChatsBlockRespectsCap() {
        let project = Project()
        context.insert(project)
        for index in 0..<5 {
            let other = Conversation(title: "C\(index)")
            other.summary = String(repeating: "s", count: 400)
            context.insert(other)
            other.project = project
        }
        let current = Conversation()
        context.insert(current)

        let block = try! #require(ContextAssembler.otherChatsBlock(for: project, excluding: current, cap: 1_000))
        #expect(block.count <= 1_000 + "[older chats omitted]".count)
        #expect(block.hasSuffix("[older chats omitted]"))
    }

    // MARK: - Agents

    @Test func agentInstructionsSitBetweenGlobalAndProject() {
        let project = Project(name: "P")
        project.customInstructions = "Project rules."
        context.insert(project)
        let agent = Agent(name: "Pirate")
        agent.instructions = " Talk like a pirate. "
        context.insert(agent)

        let conversation = Conversation()
        context.insert(conversation)
        conversation.project = project
        _ = message(.user, "hi", in: conversation, at: 0)

        let outgoing = ContextAssembler.build(for: conversation, globalInstructions: "Be brief.", agent: agent)
        #expect(outgoing.map(\.role) == [.system, .user])
        #expect(outgoing[0].content == "Be brief.\n\nTalk like a pirate.\n\nProject rules.")
    }

    @Test func agentCanReplaceGlobalInstructions() {
        let agent = Agent()
        agent.instructions = "Talk like a pirate."
        agent.replacesGlobalInstructions = true
        context.insert(agent)
        let conversation = Conversation()
        context.insert(conversation)
        _ = message(.user, "hi", in: conversation, at: 0)

        let outgoing = ContextAssembler.build(for: conversation, globalInstructions: "Be brief.", agent: agent)
        #expect(outgoing[0].content == "Talk like a pirate.")
    }

    @Test func emptyAgentAddsNoSystemMessage() {
        let agent = Agent()
        context.insert(agent)
        let conversation = Conversation()
        context.insert(conversation)
        _ = message(.user, "hi", in: conversation, at: 0)

        let outgoing = ContextAssembler.build(for: conversation, agent: agent)
        #expect(outgoing.map(\.role) == [.user])
    }

    @Test func agentOverridesGenerationOptions() {
        let base = GenerationOptions(temperature: 0.2, maxTokens: 500)
        let agent = Agent()
        var options = agent.generationOptions(over: base)
        #expect(options.temperature == 0.2 && options.maxTokens == 500)

        agent.temperature = 1.1
        options = agent.generationOptions(over: base)
        #expect(options.temperature == 1.1 && options.maxTokens == 500)

        agent.maxTokens = 64
        options = agent.generationOptions(over: GenerationOptions())
        #expect(options.temperature == 1.1 && options.maxTokens == 64)
    }

    @Test func newProjectChatStartsWithDefaultAgent() {
        let fallback = ProviderConfig(name: "Default")
        fallback.isDefault = true
        fallback.preferredModelID = "default-model"
        let other = ProviderConfig(name: "Other")
        context.insert(fallback)
        context.insert(other)

        let agent = Agent(name: "Pirate")
        agent.providerKeychainKey = other.keychainKey
        agent.modelID = "pirate-model"
        context.insert(agent)

        let project = Project()
        project.defaultAgentID = agent.idString
        context.insert(project)

        let providers = [fallback, other]
        let chat = Conversation.create(in: project, providers: providers, agents: [agent], context: context)
        #expect(chat.agentID == agent.idString)
        #expect(chat.providerKeychainKey == other.keychainKey)
        #expect(chat.modelID == "pirate-model")
        #expect(chat.displayModelName(agents: [agent]) == "Pirate")

        // A deleted agent leaves a dangling ID: fall back to the default provider.
        project.defaultAgentID = UUID().uuidString
        let plain = Conversation.create(in: project, providers: providers, agents: [agent], context: context)
        #expect(plain.agentID.isEmpty)
        #expect(plain.providerKeychainKey == fallback.keychainKey)
        #expect(plain.modelID == "default-model")
        #expect(plain.displayModelName(agents: [agent]) == "default-model")
    }

    // MARK: - Export and search

    @Test func exportSkipsErrors() {
        let conversation = Conversation(title: "Trip")
        context.insert(conversation)
        _ = message(.user, "Where?", in: conversation, at: 0)
        let reply = message(.assistant, "Lisbon.", in: conversation, at: 1)
        reply.modelID = "gpt-x"
        let failed = message(.assistant, "", in: conversation, at: 2)
        failed.isError = true

        #expect(ConversationExporter.markdown(for: conversation) == """
        # Trip

        ## You

        Where?

        ## Assistant (gpt-x)

        Lisbon.

        """)
    }

    @Test func filenameIsSanitized() {
        let conversation = Conversation(title: "a/b: c?")
        #expect(ConversationExporter.filename(for: conversation) == "a-b- c-")
    }

    @Test func searchMatchesTitleAndContent() {
        let conversation = Conversation(title: "Recipes")
        context.insert(conversation)
        _ = message(.user, "How long to boil an egg?", in: conversation, at: 0)

        let other = Conversation(title: "Other")
        context.insert(other)
        _ = message(.user, "Nothing here", in: other, at: 1)
        let all = [conversation, other]

        let byTitle = Conversation.search("recipe", in: all, context: context)
        #expect(byTitle.map(\.conversation.title) == ["Recipes"])
        #expect(byTitle.first?.excerpt == nil)
        #expect(Conversation.search("EGG", in: all, context: context).map(\.conversation.title) == ["Recipes"])
        #expect(Conversation.search("pasta", in: all, context: context).isEmpty)
        #expect(Conversation.search("boil", in: all, context: context).first?.excerpt == "How long to boil an egg?")
    }

    @Test func excerptIsTrimmedAroundMatch() {
        let text = String(repeating: "a", count: 100) + " needle " + String(repeating: "b", count: 100)
        let excerpt = try! #require(SearchExcerpt.make(from: text, around: "needle", radius: 5))
        #expect(excerpt == "\u{2026}aaaa needle bbbb\u{2026}")
        #expect(SearchExcerpt.make(from: text, around: "missing") == nil)
    }
}
