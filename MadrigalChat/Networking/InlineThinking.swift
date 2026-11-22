import Foundation

/// Thinking that reasoning models write inline in their answer text.
enum InlineThinking {
    /// Splits thinking that a model writes inline as `<think>...</think>`
    /// (DeepSeek R1 distills, QwQ, and others served without a reasoning
    /// parser) out of the answer text. Some of these omit the opening tag and
    /// only emit `</think>`. Works on a partial stream: an unclosed `<think>`
    /// means everything so far is reasoning.
    ///
    /// A model that calls tools thinks again in each round, so once a reply
    /// has opened with a think block, later blocks are split out too.
    static func split(_ raw: String) -> (reasoning: String, answer: String) {
        let first = splitLeadingThinking(raw)
        guard !first.reasoning.isEmpty || first.answer != raw else { return first }

        var reasoning = first.reasoning.isEmpty ? [] : [first.reasoning]
        var answer: [String] = []
        var rest = first.answer
        while let open = rest.range(of: "<think>") {
            answer.append(String(rest[..<open.lowerBound]))
            let next = splitLeadingThinking(String(rest[open.lowerBound...]))
            if !next.reasoning.isEmpty { reasoning.append(next.reasoning) }
            rest = next.answer
        }
        answer.append(rest)
        return (
            reasoning.joined(separator: "\n\n"),
            answer.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        )
    }

    private static func splitLeadingThinking(_ raw: String) -> (reasoning: String, answer: String) {
        let open = "<think>", close = "</think>"
        let trimmed = raw.drop { $0.isWhitespace }

        if trimmed.hasPrefix(open) {
            let body = trimmed.dropFirst(open.count)
            guard let end = body.range(of: close) else {
                return (String(body).trimmingCharacters(in: .whitespacesAndNewlines), "")
            }
            return (String(body[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(body[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !raw.contains(open), let end = raw.range(of: close) {
            return (String(raw[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(raw[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ("", raw)
    }
}
