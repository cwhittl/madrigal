import Foundation
import Testing
import os
@testable import Madrigal
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Returns canned results and remembers the queries it was asked.
private final class FakeSearchClient: WebSearchClient, Sendable {
    let results: [SearchResult]
    let error: Error?
    private let log = OSAllocatedUnfairLock(initialState: [String]())

    init(results: [SearchResult] = [], error: Error? = nil) {
        self.results = results
        self.error = error
    }

    var queries: [String] { log.withLock { $0 } }

    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        log.withLock { $0.append(query) }
        if let error { throw error }
        return Array(results.prefix(limit))
    }
}

/// Collects the deltas a search reports.
private final class DeltaLog: Sendable {
    private let log = OSAllocatedUnfairLock(initialState: [ChatDelta]())
    var deltas: [ChatDelta] { log.withLock { $0 } }
    func append(_ delta: ChatDelta) { log.withLock { $0.append(delta) } }
}

struct WebSearchServiceTests {

    private let sample = [
        SearchResult(title: "Swift 7 released", url: "https://swift.org/blog/7", snippet: "Today we're announcing Swift 7."),
        SearchResult(title: "Swift on the server", url: "https://example.com/server", snippet: "Notes from the workgroup.")
    ]

    private func config(_ mode: WebSearchMode = .always, client: FakeSearchClient, online: Bool = true, cap: Int = 1_500) -> WebSearchConfig {
        var config = WebSearchConfig(mode: mode, client: client, characterCap: cap)
        config.isOnline = { online }
        return config
    }

    // MARK: - SearXNG

    @Test func decodesResultsSkippingDuplicatesAndMissingURLs() throws {
        let json = """
        {"query": "swift", "results": [
          {"title": "  Swift\\n 7  ", "url": "https://swift.org/blog/7", "content": "Today   we're\\nannouncing Swift 7."},
          {"title": "Dup", "url": "https://swift.org/blog/7", "content": "Again"},
          {"title": "No URL", "content": "Skipped"},
          {"url": "https://example.com/untitled"},
          {"title": "Over the limit", "url": "https://example.com/4", "content": ""}
        ]}
        """
        let results = try SearXNGClient.decode(Data(json.utf8), limit: 2)
        #expect(results == [
            SearchResult(title: "Swift 7", url: "https://swift.org/blog/7", snippet: "Today we're announcing Swift 7."),
            SearchResult(title: "https://example.com/untitled", url: "https://example.com/untitled", snippet: "")
        ])
    }

    @Test func longSnippetsAreTrimmed() throws {
        let long = String(repeating: "word ", count: 100)
        let json = #"{"results": [{"title": "T", "url": "https://a.example", "content": "\#(long)"}]}"#
        let results = try SearXNGClient.decode(Data(json.utf8), limit: 5)
        #expect(results[0].snippet.count == SearchText.snippetCharacterLimit)
        #expect(results[0].snippet.hasSuffix("\u{2026}"))
    }

    @Test func badJSONIsADecodingError() {
        #expect(throws: ChatProviderError.self) {
            try SearXNGClient.decode(Data("<html>".utf8), limit: 5)
        }
    }

    @Test func searchURLAcceptsCommonBaseForms() {
        for base in ["https://search.example.com", "https://search.example.com/", "https://search.example.com/search", " https://search.example.com/search/ "] {
            #expect(SearXNGClient.searchURL(base: base, query: "a b&c")?.absoluteString
                    == "https://search.example.com/search?q=a%20b%26c&format=json")
        }
        #expect(SearXNGClient.searchURL(base: "http://nas.local:8888/searxng", query: "x")?.absoluteString
                == "http://nas.local:8888/searxng/search?q=x&format=json")
        #expect(SearXNGClient.searchURL(base: "not a url", query: "x") == nil)
    }

    // MARK: - Formatting

    @Test func formatNumbersResults() {
        let text = WebSearchConfig.format(sample, characterCap: 1_500)
        #expect(text == """
        [1] Swift 7 released \u{2014} https://swift.org/blog/7
        Today we're announcing Swift 7.

        [2] Swift on the server \u{2014} https://example.com/server
        Notes from the workgroup.
        """)
    }

    @Test func formatStopsAtTheCap() {
        let results = (1...10).map {
            SearchResult(title: "Result \($0)", url: "https://example.com/\($0)", snippet: String(repeating: "x", count: 150))
        }
        let text = WebSearchConfig.format(results, characterCap: 600)
        #expect(text.count <= 600)
        #expect(text.contains("[1] Result 1"))
        #expect(!text.contains("[10]"))

        // A cap smaller than one result still gives the model something.
        let tiny = WebSearchConfig.format(results, characterCap: 20)
        #expect(tiny.count == 20)
        #expect(WebSearchConfig.format([], characterCap: 100) == "No results found.")
    }

    // MARK: - Running searches

    @Test func runReportsStatusThenRecord() async {
        let client = FakeSearchClient(results: sample)
        let log = DeltaLog()
        let outcome = await config(client: client).run("  swift news  ") { log.append($0) }
        #expect(client.queries == ["swift news"])
        #expect(outcome.record == WebSearchRecord(query: "swift news", results: sample))
        #expect(outcome.text.hasPrefix("[1] Swift 7 released"))
        #expect(log.deltas.map(\.status) == ["Searching: swift news", ""])
        #expect(log.deltas.last?.search == outcome.record)
    }

    @Test func offlineSkipsTheSearch() async {
        let client = FakeSearchClient(results: sample)
        let outcome = await config(client: client, online: false).run("swift")
        #expect(client.queries.isEmpty)
        #expect(outcome.record?.results.isEmpty == true)
        #expect(outcome.record?.failure?.contains("offline") == true)
        #expect(outcome.text.contains("offline"))
    }

    @Test func failureBecomesANoteNotAnError() async {
        let client = FakeSearchClient(error: ChatProviderError.unavailable(reason: "Add json to formats."))
        let log = DeltaLog()
        let outcome = await config(client: client).run("swift") { log.append($0) }
        #expect(outcome.record == WebSearchRecord(query: "swift", results: [], failure: "Add json to formats."))
        #expect(outcome.text == "Web search failed: Add json to formats.")
        // Reported, so the reply's sources show what went wrong.
        #expect(log.deltas.last?.search == outcome.record)
    }

    // MARK: - Always mode

    @Test func alwaysModeInjectsResultsAfterSystemMessages() async {
        let client = FakeSearchClient(results: sample)
        let messages = [
            OutgoingMessage(role: .system, content: "Be brief."),
            OutgoingMessage(role: .user, content: "Hi"),
            OutgoingMessage(role: .assistant, content: "Hello!"),
            OutgoingMessage(role: .user, content: "What's new in Swift?")
        ]
        let (injected, record) = await config(client: client).injectingResults(into: messages)
        #expect(client.queries == ["What's new in Swift?"])
        #expect(record?.results == sample)
        #expect(injected.map(\.role) == [.system, .system, .user, .assistant, .user])
        #expect(injected[1].content.hasPrefix("Web search results for \"What's new in Swift?\""))
        #expect(injected[1].content.contains("[2] Swift on the server"))

        // Both on-device providers fold it into their instructions.
        let turns = try? LocalMLX.chatTurns(for: injected)
        #expect(turns?.first?.content.contains("[1] Swift 7 released") == true)
    }

    @Test func alwaysModeSaysWhenNothingWasFound() async {
        let messages = [OutgoingMessage(role: .user, content: "Hi")]
        let (injected, record) = await config(client: FakeSearchClient()).injectingResults(into: messages)
        #expect(injected.map(\.role) == [.system, .user])
        #expect(injected[0].content.contains("found nothing."))
        #expect(record?.results.isEmpty == true)
        #expect(record?.failure == nil)
    }

    @Test func alwaysModeSaysWhyTheSearchFailed() async {
        let client = FakeSearchClient(error: ChatProviderError.unavailable(reason: "DuckDuckGo is limiting searches"))
        let messages = [OutgoingMessage(role: .user, content: "Hi")]
        let (injected, record) = await config(client: client).injectingResults(into: messages)
        #expect(injected.map(\.role) == [.system, .user])
        #expect(injected[0].content.contains("failed: DuckDuckGo is limiting searches. If answering"))
        #expect(record?.failure == "DuckDuckGo is limiting searches")
    }

    @Test func alwaysIsOfferedBeforeModelDecides() {
        #expect(WebSearchMode.allCases == [.off, .always, .auto])
    }

    // MARK: - Provider settings

    @Test func searchIsOnlyConfiguredForOnDeviceProviders() {
        let config = ProviderConfig()
        config.webSearchMode = .always
        config.searxngURL = "https://search.example.com"
        #expect(ProviderFactory.makeWebSearch(for: config) == nil)
        #expect(config.webSearchProblem == nil)

        config.kind = .appleIntelligence
        #expect(ProviderFactory.makeWebSearch(for: config)?.mode == .always)
        #expect(ProviderFactory.makeWebSearch(for: config)?.characterCap == WebSearchConfig.appleCharacterCap)

        config.kind = .localMLX
        #expect(ProviderFactory.makeWebSearch(for: config)?.characterCap == WebSearchConfig.mlxCharacterCap)

        config.webSearchMode = .off
        #expect(ProviderFactory.makeWebSearch(for: config) == nil)
    }

    @Test func badSearchURLsAreFlagged() {
        let config = ProviderConfig()
        config.kind = .localMLX
        config.webSearchMode = .auto
        config.webSearchBackend = .searxng
        #expect(config.webSearchProblem != nil)
        #expect(ProviderFactory.makeWebSearch(for: config) == nil)
        config.searxngURL = "http://search.example.com"
        #expect(config.webSearchProblem?.contains("https") == true)
        config.searxngURL = "http://192.168.1.20:8080"
        #expect(config.webSearchProblem == nil)
        #expect(ProviderFactory.makeWebSearch(for: config)?.client is SearXNGClient)
    }

    @Test func onDeviceSearchNeedsNoURL() {
        let config = ProviderConfig()
        config.kind = .appleIntelligence
        config.webSearchMode = .always
        #expect(config.webSearchBackend == .onDevice)
        #expect(config.webSearchProblem == nil)
        #expect(ProviderFactory.makeWebSearch(for: config)?.client is OnDeviceSearchClient)

        // A bad URL doesn't matter when it isn't used.
        config.webSearchBackend = .onDevice
        config.searxngURL = "not a url"
        #expect(config.webSearchProblem == nil)
        #expect(ProviderFactory.makeWebSearch(for: config)?.client is OnDeviceSearchClient)
    }

    @Test func configsWithAServerKeepUsingIt() {
        // Saved before the backend choice existed: no backend, but a URL.
        let config = ProviderConfig()
        config.kind = .localMLX
        config.webSearchMode = .auto
        config.searxngURL = "https://search.example.com"
        #expect(config.webSearchBackendRaw.isEmpty)
        #expect(config.webSearchBackend == .searxng)
        #expect(ProviderFactory.makeWebSearch(for: config)?.client is SearXNGClient)
    }

    @Test func braveUsesTheProvidersOwnKeychainItem() {
        let config = ProviderConfig()
        config.kind = .appleIntelligence
        config.webSearchMode = .always
        config.webSearchBackend = .brave
        #expect(config.webSearchProblem == nil)
        #expect(ProviderFactory.makeWebSearch(for: config)?.client is BraveSearchClient)
        #expect(config.braveKeychainKey == "\(config.keychainKey).brave")
    }

    @Test func agentOverridesKeepWebSearch() {
        var base = GenerationOptions(temperature: 0.2)
        base.webSearch = config(.auto, client: FakeSearchClient(), cap: 1_234)
        let agent = Agent()
        agent.temperature = 0.9
        let search = agent.generationOptions(over: base).webSearch
        #expect(search?.mode == .auto)
        #expect(search?.characterCap == 1_234)
    }

    @Test func contextReservesRoomForResults() {
        #expect(ChatViewModel.webSearchReserve(for: nil) == 0)
        #expect(ChatViewModel.webSearchReserve(for: config(client: FakeSearchClient(), cap: 1_500)) > 1_500)
    }

    // MARK: - Sources payload

    @Test func sourcesRoundTripThroughTheToolPayload() {
        let payload = ToolPayload(webSearch: [WebSearchRecord(query: "swift", results: sample)])
        #expect(payload.json.hasPrefix(#"{"webSearch":"#))
        #expect(ToolPayload(json: payload.json) == payload)
        #expect(ToolPayload().json == "")
        #expect(ToolPayload(json: "").webSearch.isEmpty)
        #expect(ToolPayload(json: "garbage").webSearch.isEmpty)

        let failed = ToolPayload(webSearch: [WebSearchRecord(query: "swift", results: [], failure: "Offline.")])
        #expect(ToolPayload(json: failed.json) == failed)
        // Saved before failures were kept.
        let old = ToolPayload(json: #"{"webSearch":[{"query":"swift","results":[]}]}"#)
        #expect(old.webSearch == [WebSearchRecord(query: "swift", results: [])])
    }

    // MARK: - Brave

    @Test func decodesBraveResults() throws {
        let json = #"""
        {"type":"search","web":{"type":"search","results":[
          {"title":"About <strong>Swift</strong>","url":"https://swift.org/about","description":"Swift is a <strong>general</strong>-purpose language &amp; more."},
          {"title":"Dup","url":"https://swift.org/about","description":"x"},
          {"title":"No URL"},
          {"url":"https://example.com/untitled","description":""}
        ]}}
        """#
        let results = try BraveSearchClient.decode(Data(json.utf8))
        #expect(results == [
            SearchResult(title: "About Swift", url: "https://swift.org/about", snippet: "Swift is a general-purpose language & more."),
            SearchResult(title: "https://example.com/untitled", url: "https://example.com/untitled", snippet: "")
        ])
        #expect(try BraveSearchClient.decode(Data(#"{"type":"search"}"#.utf8)).isEmpty)
    }

    @Test func braveWithoutAKeyFailsBeforeAnyRequest() async {
        let client = BraveSearchClient(apiKey: { "  " })
        await #expect {
            try await client.search("swift", limit: 5)
        } throws: { error in
            guard case ChatProviderError.unavailable(let reason) = error else { return false }
            return reason == BraveSearchClient.missingKeyReason
        }
    }

    // MARK: - Streaming

    @Test func statusShowsUntilTextArrivesAndSearchesAccumulate() async throws {
        let record = WebSearchRecord(query: "swift", results: sample)
        let (deltas, input) = AsyncThrowingStream<ChatDelta, Error>.makeStream()
        let snapshots = StreamAccumulator.snapshots(of: deltas, every: .milliseconds(10))
        var iterator = snapshots.makeAsyncIterator()

        input.yield(.status("Searching: swift"))
        input.yield(.search(record))
        let searching = try await iterator.next()
        #expect(searching?.status == "Searching: swift")
        #expect(searching?.received == false)

        input.yield(ChatDelta(textFragment: "Swift 7 is out [1].", isFinal: false))
        input.yield(ChatDelta(textFragment: "", isFinal: true))
        input.finish()
        var last = searching
        while let snapshot = try await iterator.next() { last = snapshot }
        #expect(last?.status == "")
        #expect(last?.answer == "Swift 7 is out [1].")
        #expect(last?.searches == [record])
    }

    @Test func laterThinkBlocksAreSplitOut() {
        let result = InlineThinking.split("<think>Need to search.</think>\n\n<think>Found it.</think>\n\nSwift 7 is out [1].")
        #expect(result.reasoning == "Need to search.\n\nFound it.")
        #expect(result.answer == "Swift 7 is out [1].")

        // Without a leading block, a <think> in the answer is just text.
        #expect(InlineThinking.split("Use <think> tags.").answer == "Use <think> tags.")
    }

    // MARK: - MLX tool loop

    @Test func mlxLoopSearchesThenAnswers() async throws {
        let client = FakeSearchClient(results: sample)
        let log = DeltaLog()
        var rounds: [(history: [LocalMLX.Turn], allowTools: Bool)] = []

        try await LocalMLX.generateWithSearch(
            turns: [OutgoingMessage(role: .user, content: "What's new in Swift?")],
            search: config(.auto, client: client, cap: 4_000),
            emit: { log.append($0) }
        ) { history, allowTools, onEvent in
            rounds.append((history, allowTools))
            if rounds.count == 1 {
                onEvent(.text("<think>I should search.</think>"))
                onEvent(.toolCall(LocalMLX.ToolRequest(id: "call_1", name: "web_search", query: "swift 7")))
            } else {
                onEvent(.text("<think>Got it.</think>Swift 7 is out [1]."))
            }
        }

        #expect(client.queries == ["swift 7"])
        #expect(rounds.map(\.allowTools) == [true, true])
        #expect(rounds[1].history.count == 3)
        guard case .toolCalls(let text, let calls) = rounds[1].history[1],
              case .toolResult(let id, let name, let content) = rounds[1].history[2] else {
            Issue.record("Expected a tool call and its result")
            return
        }
        #expect(text == "")
        #expect(calls == [LocalMLX.ToolRequest(id: "call_1", name: "web_search", query: "swift 7")])
        #expect(id == "call_1" && name == "web_search")
        #expect(content.hasPrefix("[1] Swift 7 released"))

        let streamed = log.deltas.map(\.textFragment).joined()
        let split = InlineThinking.split(streamed)
        #expect(split.answer == "Swift 7 is out [1].")
        #expect(split.reasoning == "I should search.\n\nGot it.")
        #expect(log.deltas.compactMap(\.search).map(\.query) == ["swift 7"])
        #expect(log.deltas.map(\.status).contains("Searching: swift 7"))
    }

    @Test func mlxLoopMakesTheLastRoundAnswer() async throws {
        let client = FakeSearchClient(results: sample)
        var allowed: [Bool] = []
        try await LocalMLX.generateWithSearch(
            turns: [OutgoingMessage(role: .user, content: "Search forever")],
            search: config(.auto, client: client),
            emit: { _ in }
        ) { _, allowTools, onEvent in
            allowed.append(allowTools)
            onEvent(.toolCall(LocalMLX.ToolRequest(id: nil, name: "web_search", query: "again")))
        }
        #expect(allowed == [true, true, true, false])
        #expect(client.queries.count == LocalMLX.maxSearchRounds)
    }

    @Test func mlxLoopAnswersWithoutToolsWhenALaterRoundCantTakeThem() async throws {
        let client = FakeSearchClient(results: sample)
        let log = DeltaLog()
        var allowed: [Bool] = []
        try await LocalMLX.generateWithSearch(
            turns: [OutgoingMessage(role: .user, content: "Hi")],
            search: config(.auto, client: client),
            emit: { log.append($0) }
        ) { history, allowTools, onEvent in
            allowed.append(allowTools)
            switch allowed.count {
            case 1:
                onEvent(.text("Let me look."))
                onEvent(.toolCall(LocalMLX.ToolRequest(id: nil, name: "web_search", query: "swift")))
            case 2:
                throw LocalMLX.ToolsUnsupported()
            default:
                #expect(history.count == 3)
                onEvent(.text("Found it."))
            }
        }
        #expect(allowed == [true, true, false])
        #expect(log.deltas.map(\.textFragment).joined() == "Let me look.\n\nFound it.")
    }

    @Test func mlxLoopLetsAFirstRoundToolFailureThrough() async {
        await #expect(throws: LocalMLX.ToolsUnsupported.self) {
            try await LocalMLX.generateWithSearch(
                turns: [OutgoingMessage(role: .user, content: "Hi")],
                search: config(.auto, client: FakeSearchClient()),
                emit: { _ in }
            ) { _, _, _ in throw LocalMLX.ToolsUnsupported() }
        }
    }

    @Test func mlxLoopAnswersUnknownToolsWithoutSearching() async throws {
        let client = FakeSearchClient(results: sample)
        var results: [String] = []
        try await LocalMLX.generateWithSearch(
            turns: [OutgoingMessage(role: .user, content: "Hi")],
            search: config(.auto, client: client),
            emit: { _ in }
        ) { history, _, onEvent in
            if case .toolResult(_, _, let content) = history.last { results.append(content) }
            if history.count == 1 {
                onEvent(.toolCall(LocalMLX.ToolRequest(id: nil, name: "calculator", query: nil)))
            }
        }
        #expect(client.queries.isEmpty)
        #expect(results.count == 1 && results[0].contains("Only web_search"))
    }

    // MARK: - Apple Intelligence

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    @Test func appleTranscriptDeclaresTheSearchTool() throws {
        let tool = WebSearchTool(search: config(.auto, client: FakeSearchClient())) { _ in }
        let (transcript, prompt) = try AppleIntelligenceProvider.transcript(
            for: [OutgoingMessage(role: .user, content: "News?")],
            tools: [tool]
        )
        #expect(prompt == "News?")
        guard case .instructions(let instructions) = transcript.first else {
            Issue.record("Expected instructions carrying the tool")
            return
        }
        #expect(instructions.toolDefinitions.map(\.name) == ["web_search"])
        #expect(instructions.segments.contains { segment in
            if case .text(let text) = segment { return text.content.contains("web_search") }
            return false
        })
    }

    @available(iOS 26, macOS 26, *)
    @Test func appleTranscriptHasNoToolsByDefault() throws {
        let (transcript, _) = try AppleIntelligenceProvider.transcript(for: [
            OutgoingMessage(role: .system, content: "Be brief."),
            OutgoingMessage(role: .user, content: "Hi")
        ])
        guard case .instructions(let instructions) = transcript.first else {
            Issue.record("Expected instructions")
            return
        }
        #expect(instructions.toolDefinitions.isEmpty)
    }
    #endif
}
