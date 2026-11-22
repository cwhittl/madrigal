import Foundation

/// Parses the subset of Server-Sent Events that OpenAI-style chat streaming
/// uses: `data: {json}` lines terminated by `data: [DONE]`.
///
/// Kept separate from the providers so both the OpenAI-compatible and the
/// Cloudflare paths share exactly one implementation of the frame handling.
enum SSEParser {

    enum Event {
        case chunk(String)   // raw JSON payload from a `data:` line
        case done
        case ignored         // comments, empty lines, other field names
    }

    static func event(forLine rawLine: String) -> Event {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .ignored }
        guard line.hasPrefix("data:") else { return .ignored }   // ": comment", "event:", "id:"

        let payload = String(line.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespaces)

        if payload == "[DONE]" { return .done }
        if payload.isEmpty { return .ignored }
        return .chunk(payload)
    }

    /// One streamed chat chunk. Only the fields v1 actually reads are decoded;
    /// unknown keys are ignored, which keeps this working across the small
    /// differences between OpenAI-compatible vendors.
    struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                /// DeepSeek, Qwen, vLLM, and Cloudflare use `reasoning_content`;
                /// OpenRouter, Groq, and Ollama use `reasoning`.
                let reasoningContent: String?
                let reasoning: String?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                    case reasoning
                }
            }
            let delta: Delta?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        let choices: [Choice]?
        /// OpenRouter and others report failures after the 200 has been sent,
        /// as `data: {"error":{"message":...}}`.
        let error: StreamError?
    }

    /// Either `{"message":"...","code":...}` or a bare string.
    struct StreamError: Decodable {
        let message: String

        private enum CodingKeys: String, CodingKey { case message }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self) {
                message = text
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = (try? container.decode(String.self, forKey: .message)) ?? ""
        }
    }

    /// Returns the text and reasoning fragments in a chunk, if any, plus
    /// whether the chunk carried a finish reason. Throws if the chunk is an
    /// error report.
    static func decodeChunk(_ json: String) throws -> (text: String, reasoning: String, finished: Bool) {
        guard let data = json.data(using: .utf8) else { return ("", "", false) }
        let chunk = try HTTP.decode(StreamChunk.self, from: data)
        if let error = chunk.error {
            let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ChatProviderError.streamError(message: message.isEmpty ? "Unknown error." : message)
        }
        let choice = chunk.choices?.first
        let reasoning = choice?.delta?.reasoningContent ?? choice?.delta?.reasoning ?? ""
        return (choice?.delta?.content ?? "", reasoning, choice?.finishReason != nil)
    }
}
