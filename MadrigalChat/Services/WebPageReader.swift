import Foundation

/// Reads the pages behind search results, so the model can answer from
/// what they say instead of only their snippets.
protocol WebPageReading: Sendable {
    /// The page's readable text, one block per line, or nil when it
    /// couldn't be read.
    func text(of url: URL) async -> String?
}

/// Fetches a page straight from this device and keeps its text. Pages that
/// build their content with JavaScript give little or nothing.
struct WebPageReader: WebPageReading {
    var session: URLSession = .shared

    /// Pages bigger than this are cut off; the useful part is rarely past it.
    static let byteLimit = 1_500_000

    func text(of url: URL) async -> String? {
        guard url.isPublicWebPage else { return nil }
        var request = URLRequest(url: url, timeoutInterval: HTTP.pageTimeout)
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        guard let (data, http) = try? await HTTP.data(for: request, session: session), http.isSuccess else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
        let body = String(decoding: data.prefix(Self.byteLimit), as: UTF8.self)
        if type.contains("html") { return HTMLText.lines(body).nonEmpty }
        if type.hasPrefix("text/plain") { return body.nonEmpty }
        return nil
    }
}

/// Picks the parts of a page's text that answer a query.
enum PageText {
    /// Words too common to say what a query is about.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "what", "whats", "what's", "how", "why", "who", "when",
        "where", "which", "will", "would", "can", "could", "should", "does", "did", "this", "that", "these",
        "those", "with", "from", "about", "into", "like", "going", "you", "your", "there", "their", "is",
        "it's", "its", "any", "some", "tell", "please", "give", "show", "find", "know", "get"
    ]

    /// Lowercased words of three or more letters that carry meaning.
    static func keywords(in query: String) -> Set<String> {
        let words = query.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }
        return Set(words.map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    /// Size of the pieces a page is cut into before they're ranked.
    static let chunkSize = 300

    /// The parts of `text` that best match `query`, in page order, within
    /// `budget` characters and joined by an ellipsis. Pieces matching more
    /// of the query rank first; numbers break ties, since facts are often
    /// figures. With no match, the start of the page is used.
    static func excerpt(from text: String, query: String, budget: Int) -> String {
        guard budget > 0 else { return "" }
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n") {
            if !current.isEmpty, current.count + line.count + 1 > chunkSize {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? String(line) : " " + line
        }
        if !current.isEmpty { chunks.append(current) }
        guard !chunks.isEmpty else { return "" }

        let words = keywords(in: query)
        let scored = chunks.enumerated().map { index, chunk -> (index: Int, score: Int) in
            let lower = chunk.lowercased()
            let hits = words.filter { lower.contains($0) }.count
            let hasNumber = chunk.contains { $0.isNumber }
            return (index, hits * 2 + (hits > 0 && hasNumber ? 1 : 0))
        }
        let ranked = scored.contains { $0.score > 0 }
            ? scored.filter { $0.score > 0 }.sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }.map(\.index)
            : Array(chunks.indices)

        var picked: [Int] = []
        var used = 0
        for index in ranked {
            let cost = chunks[index].count + (picked.isEmpty ? 0 : 3)
            if used + cost > budget {
                if picked.isEmpty { picked.append(index); used = budget }
                continue
            }
            picked.append(index)
            used += cost
        }
        let excerpt = picked.sorted().map { chunks[$0] }.joined(separator: " \u{2026} ")
        return excerpt.truncated(to: budget)
    }
}
