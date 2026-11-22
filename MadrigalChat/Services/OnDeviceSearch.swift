import Foundation

/// Searches without a server: asks DuckDuckGo and Wikipedia straight from
/// this device, the way SearXNG asks the engines it uses. The sources run
/// at the same time; their results are merged in source order, without
/// duplicate URLs.
struct OnDeviceSearchClient: WebSearchClient {
    var sources: [any WebSearchClient] = [
        DuckDuckGoInstantAnswerClient(),
        DuckDuckGoHTMLClient(),
        WikipediaSearchClient()
    ]

    /// Returns what the sources that worked found. Throws the first
    /// source's error when every source failed, or when the ones that
    /// worked found nothing, so a blocked search isn't mistaken for an
    /// empty one.
    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        let outcomes = await withTaskGroup(of: (Int, Result<[SearchResult], Error>).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await source.search(query, limit: limit)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var outcomes: [(Int, Result<[SearchResult], Error>)] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return try Self.merge(outcomes, limit: limit)
    }

    static func merge(_ outcomes: [Result<[SearchResult], Error>], limit: Int) throws -> [SearchResult] {
        let found = outcomes.compactMap { try? $0.get() }
        let results = Array(found.joined()).uniquedByURL(limit: limit)
        if found.isEmpty || results.isEmpty {
            for case .failure(let error) in outcomes { throw error }
        }
        return results
    }
}

// MARK: - DuckDuckGo Instant Answer API

/// DuckDuckGo's official Instant Answer API. Needs no key, but only gives
/// quick answers and topic summaries, not general web results.
struct DuckDuckGoInstantAnswerClient: WebSearchClient {
    var session: URLSession = .shared

    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        let url = try URL.api("https://api.duckduckgo.com/", query: [
            "q": query,
            "format": "json",
            "no_html": "1",
            "skip_disambig": "1"
        ])
        let request = URLRequest(url: url, timeoutInterval: HTTP.searchTimeout)
        let data = try await HTTP.successfulData(for: request, session: session)
        return Array(try Self.decode(data, query: query).prefix(limit))
    }

    /// The answer and definition first, then the abstract, then related
    /// topics. The API labels its JSON `application/x-javascript`, so the
    /// body is decoded regardless of content type.
    static func decode(_ data: Data, query: String) throws -> [SearchResult] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ChatProviderError.decoding(error)
        }
        guard let json = object as? [String: Any] else { throw ChatProviderError.invalidResponse }

        var results: [SearchResult] = []
        // `Answer` is usually a string but some answer types send an object.
        if let answer = (json["Answer"] as? String).map(SearchText.collapse)?.nonEmpty {
            results.append(SearchResult(title: "DuckDuckGo answer", url: answerURL(for: query), snippet: SearchText.snippet(answer)))
        }
        if let definition = string(json, "Definition"), let url = string(json, "DefinitionURL") {
            let source = string(json, "DefinitionSource") ?? "Definition"
            results.append(SearchResult(title: source, url: url, snippet: SearchText.snippet(definition)))
        }
        if let abstract = string(json, "AbstractText"), let url = string(json, "AbstractURL") {
            results.append(SearchResult(title: string(json, "Heading") ?? url, url: url, snippet: SearchText.snippet(abstract)))
        }
        for key in ["Results", "RelatedTopics"] {
            for topic in topics(json[key]) {
                guard let text = string(topic, "Text"), let url = string(topic, "FirstURL") else { continue }
                let title = text.components(separatedBy: " - ").first?.nonEmpty ?? text
                results.append(SearchResult(title: title.truncated(to: 100), url: url, snippet: SearchText.snippet(text)))
            }
        }
        return results
    }

    /// Flattens topic groups, which hold their topics under `Topics`.
    private static func topics(_ value: Any?) -> [[String: Any]] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.flatMap { item in
            item["Topics"] != nil ? topics(item["Topics"]) : [item]
        }
    }

    private static func string(_ json: [String: Any], _ key: String) -> String? {
        (json[key] as? String).map(SearchText.collapse)?.nonEmpty
    }

    /// Answers have no page of their own, so they link to the search.
    static func answerURL(for query: String) -> String {
        (try? URL.api("https://duckduckgo.com/", query: ["q": query]))?.absoluteString ?? "https://duckduckgo.com/"
    }
}

// MARK: - DuckDuckGo HTML results

/// DuckDuckGo's no-JavaScript results page, for general web results. It's
/// unofficial, so it's parsed from known markup, and DuckDuckGo may
/// rate-limit it with a bot check.
struct DuckDuckGoHTMLClient: WebSearchClient {
    var session: URLSession = .shared

    static let rateLimitedReason = "DuckDuckGo is limiting searches from this device right now. Try again shortly."

    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        let url = try URL.api("https://html.duckduckgo.com/html/", query: ["q": query])
        var request = URLRequest(url: url, timeoutInterval: HTTP.searchTimeout)
        request.setValue(HTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, http) = try await HTTP.data(for: request, session: session)
        // DuckDuckGo answers its bot check with 202.
        if http.statusCode == 202 { throw ChatProviderError.unavailable(reason: Self.rateLimitedReason) }
        try HTTP.ensureSuccess(http, data: data)
        return Array(try Self.parse(data).prefix(limit))
    }

    private static let blockStart = regex(#"<div[^>]*\bclass="([^"]*\bresult\b[^"]*)""#)
    private static let titleLink = regex(#"<a([^>]*\bclass="[^"]*\bresult__a\b[^"]*"[^>]*)>(.*?)</a>"#)
    private static let snippet = regex(#"<(a|div|td)[^>]*\bclass="[^"]*\bresult__snippet\b[^"]*"[^>]*>(.*?)</\1>"#)
    private static let href = regex(#"\bhref="([^"]*)""#)

    /// Results in page order, skipping ads. Throws when the page is the
    /// bot check instead of results.
    static func parse(_ data: Data) throws -> [SearchResult] {
        let html = String(decoding: data, as: UTF8.self)
        if html.contains("anomaly-modal") { throw ChatProviderError.unavailable(reason: rateLimitedReason) }

        let ns = html as NSString
        let starts = blockStart.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var results: [SearchResult] = []
        for (index, start) in starts.enumerated() {
            let classes = ns.substring(with: start.range(at: 1))
            if classes.contains("result--ad") { continue }
            let end = index + 1 < starts.count ? starts[index + 1].range.location : ns.length
            let block = ns.substring(with: NSRange(location: start.range.location, length: end - start.range.location))
            let blockNS = block as NSString
            let blockRange = NSRange(location: 0, length: blockNS.length)

            guard let link = titleLink.firstMatch(in: block, range: blockRange) else { continue }
            let attributes = blockNS.substring(with: link.range(at: 1))
            guard let hrefMatch = href.firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length)),
                  let url = resultURL((attributes as NSString).substring(with: hrefMatch.range(at: 1))) else { continue }
            let title = HTMLText.plain(blockNS.substring(with: link.range(at: 2)))
            let snippetText = snippet.firstMatch(in: block, range: blockRange)
                .map { HTMLText.plain(blockNS.substring(with: $0.range(at: 2))) } ?? ""
            results.append(SearchResult(title: title.nonEmpty ?? url, url: url, snippet: SearchText.snippet(snippetText)))
        }
        return results
    }

    /// The real address behind a result link. DuckDuckGo wraps links as
    /// `//duckduckgo.com/l/?uddg=<encoded url>`. Its own ad links are
    /// dropped.
    static func resultURL(_ href: String) -> String? {
        var link = HTMLText.decodeEntities(href)
        if link.hasPrefix("//") { link = "https:" + link }
        guard let components = URLComponents(string: link), let host = components.host?.lowercased() else { return nil }
        if host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com") {
            guard components.path == "/l/",
                  let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
                  let url = URL(string: target), url.scheme != nil else { return nil }
            return target
        }
        return components.scheme == nil ? nil : link
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo should fail loudly in tests.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }
}

// MARK: - Wikipedia

/// Wikipedia's search API, in the device's language.
struct WikipediaSearchClient: WebSearchClient {
    var language: String = Locale.apiLanguageCode
    var session: URLSession = .shared

    /// Wikimedia asks API clients to identify themselves.
    static let userAgent = "Madrigal/\(AppConfig.version) (Apple app)"

    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        // The host comes from the language, so this one can fail.
        let url = try URL.api("https://\(language).wikipedia.org/w/api.php", query: [
            "action": "query",
            "list": "search",
            "srsearch": query,
            "srlimit": "\(min(limit, 3))",
            "format": "json",
            "utf8": "1"
        ])
        var request = URLRequest(url: url, timeoutInterval: HTTP.searchTimeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await HTTP.successfulData(for: request, session: session)
        return Array(try Self.decode(data, language: language).prefix(limit))
    }

    private struct Response: Decodable {
        struct Query: Decodable {
            struct Hit: Decodable {
                let title: String
                let snippet: String?
            }
            let search: [Hit]
        }
        let query: Query?
    }

    static func decode(_ data: Data, language: String) throws -> [SearchResult] {
        let response = try HTTP.decode(Response.self, from: data)
        return (response.query?.search ?? []).compactMap { hit in
            guard let url = articleURL(title: hit.title, language: language) else { return nil }
            return SearchResult(title: hit.title, url: url, snippet: SearchText.snippet(HTMLText.plain(hit.snippet ?? "")))
        }
    }

    static func articleURL(title: String, language: String) -> String? {
        guard let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: articlePathAllowed) else { return nil }
        return "https://\(language).wikipedia.org/wiki/\(path)"
    }

    private static let articlePathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))
}
