import Foundation

/// A short single-line excerpt of `text` around the first match of a query.
enum SearchExcerpt {
    static func make(from text: String, around query: String, radius: Int = 40) -> String? {
        guard !query.isEmpty,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }

        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex

        var excerpt = String(text[start..<end])
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if start > text.startIndex { excerpt = "\u{2026}" + excerpt }
        if end < text.endIndex { excerpt += "\u{2026}" }
        return excerpt
    }
}
