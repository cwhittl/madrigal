import Foundation
import Testing
@testable import Madrigal

struct SSEParserTests {

    @Test func dataLinesBecomeChunks() {
        guard case .chunk(let json) = SSEParser.event(forLine: #"data: {"a":1}"#) else {
            Issue.record("expected a chunk")
            return
        }
        #expect(json == #"{"a":1}"#)
    }

    @Test func doneAndIgnoredLines() {
        guard case .done = SSEParser.event(forLine: "data: [DONE]") else {
            Issue.record("expected done")
            return
        }
        for line in ["", ": keep-alive", "event: message", "id: 4", "data:"] {
            guard case .ignored = SSEParser.event(forLine: line) else {
                Issue.record("expected \(line) to be ignored")
                return
            }
        }
    }

    @Test func decodesContentAndFinish() throws {
        let chunk = try SSEParser.decodeChunk(#"{"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)
        #expect(chunk.text == "Hi")
        #expect(chunk.reasoning == "")
        #expect(!chunk.finished)

        let last = try SSEParser.decodeChunk(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        #expect(last.finished)
    }

    @Test(arguments: ["reasoning_content", "reasoning"])
    func decodesReasoningUnderEitherKey(key: String) throws {
        let chunk = try SSEParser.decodeChunk(#"{"choices":[{"delta":{"\#(key)":"hmm"}}]}"#)
        #expect(chunk.reasoning == "hmm")
        #expect(chunk.text == "")
    }

    @Test func chunkWithoutChoicesIsEmpty() throws {
        let chunk = try SSEParser.decodeChunk(#"{"id":"x","usage":{"total_tokens":3}}"#)
        #expect(chunk.text == "" && chunk.reasoning == "" && !chunk.finished)
    }

    @Test func midStreamErrorObjectThrows() {
        let json = #"{"error":{"code":502,"message":"Provider returned error"},"choices":[{"delta":{"content":""},"finish_reason":"error"}]}"#
        #expect {
            try SSEParser.decodeChunk(json)
        } throws: { error in
            guard case ChatProviderError.streamError(let message) = error else { return false }
            return message == "Provider returned error"
        }
    }

    @Test func midStreamErrorStringThrows() {
        #expect {
            try SSEParser.decodeChunk(#"{"error":"model overloaded"}"#)
        } throws: { error in
            guard case ChatProviderError.streamError(let message) = error else { return false }
            return message == "model overloaded"
        }
    }

    @Test func malformedJSONIsADecodingError() {
        #expect {
            try SSEParser.decodeChunk("{not json")
        } throws: { error in
            guard case ChatProviderError.decoding = error else { return false }
            return true
        }
    }

    // MARK: - Inline thinking

    @Test func splitsClosedThinkBlock() {
        let result = InlineThinking.split("<think>plan it</think>\n\nThe answer.")
        #expect(result.reasoning == "plan it")
        #expect(result.answer == "The answer.")
    }

    @Test func unclosedThinkIsAllReasoning() {
        let result = InlineThinking.split("  <think>still going")
        #expect(result.reasoning == "still going")
        #expect(result.answer == "")
    }

    @Test func closingTagOnly() {
        let result = InlineThinking.split("reasoned</think>answer")
        #expect(result.reasoning == "reasoned")
        #expect(result.answer == "answer")
    }

    @Test func plainTextPassesThrough() {
        let result = InlineThinking.split("Just text, with <b>tags</b>.")
        #expect(result.reasoning == "")
        #expect(result.answer == "Just text, with <b>tags</b>.")
    }
}

struct ProviderRequestTests {

    @Test func modelListInDataEnvelope() throws {
        let data = Data(#"{"object":"list","data":[{"id":"b"},{"id":"a"}]}"#.utf8)
        #expect(try OpenAICompatibleProvider.decodeModelIDs(from: data) == ["a", "b"])
    }

    @Test func modelListAsBareArray() throws {
        let data = Data(#"[{"id":"together/model","type":"chat"}]"#.utf8)
        #expect(try OpenAICompatibleProvider.decodeModelIDs(from: data) == ["together/model"])
    }

    @Test func geminiModelPrefixIsStripped() throws {
        let data = Data(#"{"data":[{"id":"models/gemini-2.5-flash"}]}"#.utf8)
        #expect(try OpenAICompatibleProvider.decodeModelIDs(from: data) == ["gemini-2.5-flash"])
    }

    @Test func optionsAreOmittedWhenUnset() throws {
        let provider = OpenAICompatibleProvider(baseURL: "https://openrouter.ai/api/v1", apiKey: "k")
        let body = provider.requestBody(messages: [], model: "m", options: GenerationOptions())
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        #expect(Set(json.keys) == ["model", "messages", "stream"])
    }

    @Test func requestBodyEncodesRolesAndStream() throws {
        let provider = OpenAICompatibleProvider(baseURL: "https://openrouter.ai/api/v1", apiKey: "k")
        let body = provider.requestBody(
            messages: [OutgoingMessage(role: .system, content: "s"), OutgoingMessage(role: .user, content: "u")],
            model: "m", options: GenerationOptions()
        )
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        #expect(json["stream"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "s"], ["role": "user", "content": "u"]])
    }

    @Test(arguments: [
        (#"{"error":{"message":"bad key"}}"#, "bad key"),
        (#"{"error":"rate limited"}"#, "rate limited"),
        (#"{"success":false,"errors":[{"message":"a"},{"message":"b"}]}"#, "a; b"),
        (#"{"message":"top level"}"#, "top level"),
        (#"{"error":42,"message":"fallback"}"#, "fallback"),
        ("plain text failure", "plain text failure"),
    ])
    func errorBodiesAreReadable(body: String, expected: String) {
        #expect(OpenAICompatibleProvider.humanReadableError(from: Data(body.utf8)) == expected)
    }

    @Test func maxTokensKeyDependsOnHost() {
        let options = GenerationOptions(temperature: 0.5, maxTokens: 256)

        let openAI = OpenAICompatibleProvider(baseURL: "https://api.openai.com/v1", apiKey: "k")
            .requestBody(messages: [], model: "m", options: options)
        #expect(openAI.maxCompletionTokens == 256)
        #expect(openAI.maxTokens == nil)

        let other = OpenAICompatibleProvider(baseURL: "https://api.mistral.ai/v1", apiKey: "k")
            .requestBody(messages: [], model: "m", options: options)
        #expect(other.maxTokens == 256)
        #expect(other.maxCompletionTokens == nil)
        #expect(other.temperature == 0.5)
    }

    @Test(arguments: [
        ("localhost", true), ("mac-studio.local", true), ("nas", true),
        ("192.168.1.20", true), ("::1", true),
        ("api.example.com", false), ("example.local.com", false)
    ])
    func localNetworkHosts(host: String, isLocal: Bool) {
        #expect(ProviderConfig.isLocalNetworkHost(host) == isLocal)
    }

    @Test func plainHTTPToTheInternetIsFlagged() {
        let config = ProviderConfig(name: "x", baseURL: "http://api.example.com/v1")
        #expect(config.configurationProblem != nil)
        config.baseURL = "http://192.168.1.20:1234/v1"
        #expect(config.configurationProblem == nil)
    }
}
