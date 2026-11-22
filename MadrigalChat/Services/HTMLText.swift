import Foundation

/// Plain text from HTML fragments. `NSAttributedString(html:)` would do
/// this, but it's slow and main-thread only.
enum HTMLText {
    /// Whole elements that are never readable content.
    private static let hiddenBlock = try! NSRegularExpression(
        pattern: "<(script|style|noscript|svg|template|head|nav|footer|header|form|iframe|select)\\b[^>]*>.*?</\\1\\s*>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let comment = try! NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators])
    /// Tags that separate words. Others, like `<b>`, can sit mid-word.
    private static let blockTag = try! NSRegularExpression(
        pattern: "<(br|hr|/?p|/?div|/?li|/?tr|/?td|/?th|/?h[1-6]|/?section|/?article|/?table|/?ul|/?ol|/?dt|/?dd|/?main)\\b[^>]*>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let tag = try! NSRegularExpression(pattern: "<[^>]*>", options: [.dotMatchesLineSeparators])
    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);")

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "deg": "°", "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "middot": "·",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}"
    ]

    /// Tags removed, entities decoded, whitespace collapsed.
    static func plain(_ html: String) -> String {
        SearchText.collapse(decodeEntities(replacing([(blockTag, " "), (tag, "")], in: html)))
    }

    /// A whole page's text with each block on its own line, collapsed.
    /// Scripts, styles, navigation and the like are dropped.
    static func lines(_ html: String) -> String {
        let text = replacing([(comment, " "), (hiddenBlock, " "), (blockTag, "\n"), (tag, "")], in: html)
        return decodeEntities(text)
            .components(separatedBy: .newlines)
            .map(SearchText.collapse)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func replacing(_ replacements: [(NSRegularExpression, String)], in html: String) -> String {
        replacements.reduce(html) { text, replacement in
            replacement.0.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: replacement.1
            )
        }
    }

    /// Decodes the common named entities and numeric ones. Unknown entities
    /// are left as they are.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in entity.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = ns.substring(with: match.range(at: 1))
            output += decode(name) ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    private static func decode(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[name.lowercased()]
    }
}
