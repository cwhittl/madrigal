import Foundation

/// How an on-device provider uses the web. Off by default: turning it on
/// sends search queries to the chosen `WebSearchBackend`.
enum WebSearchMode: String, CaseIterable, Identifiable, Sendable {
    /// Never searches.
    case off
    /// Searches the user's last message before every reply and adds the
    /// results to the instructions. Works with any model, including ones
    /// that can't call tools, so it's offered first.
    case always
    /// The model decides, through a `web_search` tool call. Small on-device
    /// models often don't call it.
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .always: return "Always search"
        case .auto: return "Model decides"
        }
    }
}

/// Where an on-device provider's searches go.
enum WebSearchBackend: String, CaseIterable, Identifiable, Sendable {
    /// Queries DuckDuckGo and Wikipedia straight from this device. No
    /// server needed.
    case onDevice
    /// Brave's Search API, with the user's own key.
    case brave
    /// The user's own SearXNG server.
    case searxng

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: return "On device"
        case .brave: return "Brave Search API"
        case .searxng: return "SearXNG server"
        }
    }
}

struct SearchResult: Codable, Sendable, Hashable {
    let title: String
    let url: String
    let snippet: String
}

extension Array where Element == SearchResult {
    /// The first `limit` results with a URL, without repeated URLs.
    func uniquedByURL(limit: Int = .max) -> [SearchResult] {
        var seen = Set<String>()
        var results: [SearchResult] = []
        for result in self where !result.url.isEmpty && seen.insert(result.url).inserted {
            guard results.count < limit else { break }
            results.append(result)
        }
        return results
    }
}

/// One search and what it found. Stored on the reply as its sources.
struct WebSearchRecord: Codable, Sendable, Equatable {
    let query: String
    let results: [SearchResult]
    /// Why the search didn't run or failed, shown with the sources. nil
    /// when it worked, and for records saved before failures were kept.
    var failure: String? = nil
}

/// What's stored in `Message.toolPayloadJSON`.
struct ToolPayload: Codable, Sendable, Equatable {
    var webSearch: [WebSearchRecord] = []

    var json: String {
        guard !webSearch.isEmpty,
              let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    init(webSearch: [WebSearchRecord] = []) {
        self.webSearch = webSearch
    }

    init(json: String) {
        guard !json.isEmpty,
              let payload = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return }
        self = payload
    }
}

protocol WebSearchClient: Sendable {
    func search(_ query: String, limit: Int) async throws -> [SearchResult]
}

/// Queries a self-hosted SearXNG instance through its JSON API. The JSON
/// format is off by default in SearXNG, which answers 403 until it's
/// enabled in `settings.yml`.
struct SearXNGClient: WebSearchClient {
    let baseURL: String
    var session: URLSession = .shared

    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        guard let url = Self.searchURL(base: baseURL, query: query) else {
            throw ChatProviderError.invalidURL(baseURL)
        }
        var request = URLRequest(url: url, timeoutInterval: HTTP.searchTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, http) = try await HTTP.data(for: request, session: session)
        if http.statusCode == 403 {
            throw ChatProviderError.unavailable(
                reason: "The SearXNG server refused a JSON search (403). Add json to search: formats: [html, json] in its settings.yml."
            )
        }
        try HTTP.ensureSuccess(http, data: data)
        return try Self.decode(data, limit: limit)
    }

    /// `{base}/search?q=…&format=json`. Accepts the base with or without a
    /// trailing slash or `/search`.
    static func searchURL(base: String, query: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingSuffix("/")
        if trimmed.hasSuffix("/search") { trimmed.removeLast("/search".count) }
        guard var components = URLComponents(string: trimmed + "/search"),
              components.scheme != nil, components.host != nil else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json")
        ]
        return components.url
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            let title: String?
            let url: String?
            let content: String?
        }
        let results: [Result]
    }

    /// Keeps the first `limit` results with a URL, without duplicates, and
    /// trims snippets so they fit small context windows.
    static func decode(_ data: Data, limit: Int) throws -> [SearchResult] {
        let response = try HTTP.decode(Response.self, from: data)
        return response.results.compactMap { result in
            guard let url = result.url?.nonEmpty else { return nil }
            return SearchResult(
                title: SearchText.collapse(result.title ?? "").nonEmpty ?? url,
                url: url,
                snippet: SearchText.snippet(result.content ?? "")
            )
        }
        .uniquedByURL(limit: limit)
    }
}

/// Text cleanup shared by the search clients.
enum SearchText {
    /// Snippets are trimmed to this so several fit small context windows.
    static let snippetCharacterLimit = 200

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Collapsed and trimmed to `snippetCharacterLimit`.
    static func snippet(_ text: String) -> String {
        collapse(text).truncated(to: snippetCharacterLimit)
    }
}

/// A provider's web search settings for one request, carried to the
/// provider in `GenerationOptions`.
struct WebSearchConfig: Sendable {
    let mode: WebSearchMode
    let client: any WebSearchClient
    /// Character budget for one search's formatted results.
    let characterCap: Int
    var resultLimit: Int = 5
    /// Opens the top results so the model can answer from the pages, not
    /// just their snippets. nil reads nothing.
    var pageReader: (any WebPageReading)? = nil
    /// How many of the top results `pageReader` opens.
    var pagesToRead: Int = 0
    /// Adds a forecast for weather questions. nil skips it.
    var weather: (any WeatherLookup)? = nil
    var isOnline: @Sendable () async -> Bool = { await NetworkMonitor.shared.isOnline }

    /// Apple's model has about 4,000 tokens for everything, so results are
    /// trimmed hard there, and only one page is read.
    static let appleCharacterCap = 1_500
    static let applePagesToRead = 1
    static let mlxCharacterCap = 6_000
    static let mlxPagesToRead = 3

    /// Share of the cap that page excerpts may use, leaving the rest for
    /// the other results' snippets.
    static let pageShare = 0.65

    static let toolName = "web_search"
    static let toolDescription = "Searches the web. Use it for recent events, current facts, or anything you aren't sure of."
    static let queryDescription = "A short web search query, a few keywords."
    static let toolGuidance = "You can call the web_search tool to look things up online. Use it for recent events or facts you aren't sure of. Answer from what the results say, citing them as [n]; don't just point the user to links."

    /// Search queries are kept short; a whole pasted message makes a poor query.
    static let queryCharacterLimit = 300

    static func statusText(for query: String) -> String {
        "Searching: \(query)"
    }

    struct Outcome: Sendable {
        /// What the model sees: formatted results, or a short note saying
        /// why there are none.
        let text: String
        /// nil only when there was no query. A search that couldn't run or
        /// failed has a record with its `failure`.
        let record: WebSearchRecord?
    }

    /// Runs one search. Never throws: a failed search becomes a note the
    /// model can mention, rather than failing the reply. `report` receives
    /// a status delta before the search and the record after it.
    func run(_ query: String, report: @Sendable (ChatDelta) -> Void = { _ in }) async -> Outcome {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).truncated(to: Self.queryCharacterLimit)
        guard !query.isEmpty else { return Outcome(text: "No search query was given.", record: nil) }
        guard await isOnline() else {
            let record = WebSearchRecord(query: query, results: [], failure: "This device is offline.")
            report(.search(record))
            return Outcome(text: "Web search is unavailable because this device is offline.", record: record)
        }

        report(.status(Self.statusText(for: query)))
        async let forecast = weather?.forecast(for: query)
        let searched: Result<[SearchResult], Error>
        do {
            searched = .success(try await client.search(query, limit: resultLimit))
        } catch {
            searched = .failure(error)
        }
        let weatherResult = await forecast
        if Task.isCancelled { return Outcome(text: "Web search was cancelled.", record: nil) }

        let found: [SearchResult]
        switch searched {
        case .success(let results):
            found = results
        case .failure(let error) where weatherResult == nil:
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let record = WebSearchRecord(query: query, results: [], failure: reason)
            report(.search(record))
            return Outcome(text: "Web search failed: \(reason)", record: record)
        case .failure:
            // The forecast is enough to answer a weather question.
            found = []
        }

        // A forecast already answers the question; weather pages mostly
        // build themselves with JavaScript anyway.
        let pages = weatherResult == nil ? await readPages(of: found, report: report) : [:]
        if Task.isCancelled { return Outcome(text: "Web search was cancelled.", record: nil) }

        let results = (weatherResult.map { [$0] } ?? []) + found
        let record = WebSearchRecord(query: query, results: results)
        report(.search(record))
        return Outcome(text: Self.format(results, pages: pages, query: query, characterCap: characterCap), record: record)
    }

    static func readingStatusText(pageCount: Int) -> String {
        pageCount == 1 ? "Reading 1 page" : "Reading \(pageCount) pages"
    }

    /// The text of the top results' pages, keyed by result URL. Pages that
    /// couldn't be read are left out.
    private func readPages(of results: [SearchResult], report: @Sendable (ChatDelta) -> Void) async -> [String: String] {
        guard let pageReader, pagesToRead > 0 else { return [:] }
        let targets = results.prefix(pagesToRead).compactMap { result in
            URL(string: result.url).map { (result.url, $0) }
        }
        guard !targets.isEmpty else { return [:] }
        report(.status(Self.readingStatusText(pageCount: targets.count)))
        return await withTaskGroup(of: (String, String?).self) { group in
            for (key, url) in targets {
                group.addTask { (key, await pageReader.text(of: url)) }
            }
            var pages: [String: String] = [:]
            for await (key, text) in group {
                if let text { pages[key] = text }
            }
            return pages
        }
    }

    /// Searches the last user message and adds the results as a system
    /// message after any existing ones. Both on-device providers fold system
    /// messages into their instructions. When the search found nothing or
    /// failed, a note saying so is added instead, so the model can tell the
    /// user rather than guess.
    func injectingResults(
        into messages: [OutgoingMessage],
        report: @Sendable (ChatDelta) -> Void = { _ in }
    ) async -> (messages: [OutgoingMessage], record: WebSearchRecord?) {
        guard let lastUser = messages.last(where: { $0.role == .user }) else { return (messages, nil) }
        let outcome = await run(lastUser.content, report: report)
        guard let record = outcome.record else { return (messages, nil) }
        return (Self.inject(Self.instructions(for: record, formatted: outcome.text), into: messages), record)
    }

    /// The system message text for an "always" search.
    static func instructions(for record: WebSearchRecord, formatted results: String) -> String {
        if !record.results.isEmpty {
            let date = Date.now.formatted(date: .long, time: .omitted)
            return "Web search results for \"\(record.query)\", retrieved \(date). Answer the user's question directly from what these results say, citing them as [n]. Don't just list the links or tell the user to visit them.\n\n\(results)"
        }
        var what = record.failure.map { "failed: \($0)" } ?? "found nothing"
        if !what.hasSuffix(".") { what += "." }
        return "A web search for \"\(record.query)\" was run before this reply, but it \(what) If answering needs current information, tell the user the search didn't work instead of guessing."
    }

    static func inject(_ content: String, into messages: [OutgoingMessage]) -> [OutgoingMessage] {
        let block = OutgoingMessage(role: .system, content: content)
        var messages = messages
        let index = messages.firstIndex { $0.role != .system } ?? messages.endIndex
        messages.insert(block, at: index)
        return messages
    }

    /// `[n] title — url` then the snippet, numbered from 1, stopping once
    /// the next result wouldn't fit in `characterCap`. Results with page
    /// text get the parts of it that best match `query`, sharing
    /// `pageShare` of the cap.
    static func format(
        _ results: [SearchResult],
        pages: [String: String] = [:],
        query: String = "",
        characterCap: Int
    ) -> String {
        guard !results.isEmpty else { return "No results found." }
        let readCount = results.filter { pages[$0.url] != nil }.count
        let pageBudget = readCount == 0 ? 0 : Int(Double(characterCap) * pageShare) / readCount
        var entries: [String] = []
        var total = 0
        for (index, result) in results.enumerated() {
            var entry = "[\(index + 1)] \(result.title) \u{2014} \(result.url)"
            if !result.snippet.isEmpty { entry += "\n\(result.snippet)" }
            if let page = pages[result.url] {
                let excerpt = PageText.excerpt(from: page, query: query, budget: pageBudget)
                if !excerpt.isEmpty { entry += "\nFrom the page: \(excerpt)" }
            }
            let added = entry.count + (entries.isEmpty ? 0 : 2)
            if total + added > characterCap {
                // Always give the model something, even if it's cut short.
                if entries.isEmpty { entries.append(String(entry.prefix(characterCap))) }
                break
            }
            entries.append(entry)
            total += added
        }
        return entries.joined(separator: "\n\n")
    }
}
