import Foundation
import Testing
@testable import Madrigal

/// Returns canned results or throws, standing in for one search source.
private struct FakeSource: WebSearchClient {
    var results: [SearchResult] = []
    var error: Error?
    var delay: Duration = .zero

    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        return Array(results.prefix(limit))
    }
}

private func result(_ url: String, _ title: String = "T") -> SearchResult {
    SearchResult(title: title, url: url, snippet: "")
}

struct OnDeviceSearchTests {
    // MARK: - DuckDuckGo HTML

    private let page = """
    <html><body>
    <div class="result results_links results_links_deep result--ad ">
      <div class="links_main links_deep result__body">
        <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_domain=ads.example">Buy things</a></h2>
        <a class="result__snippet" href="#">An ad.</a>
      </div>
    </div>
    <div class="result results_links results_links_deep web-result ">
      <div class="links_main links_deep result__body">
        <h2 class="result__title">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2Fabout%2F%3Fa%3D1%26b%3D2&amp;rut=abc">About <b>Swift</b> &amp; more</a>
        </h2>
        <a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">Swift is a <b>general</b>-purpose language &#8212; fast &#x26; safe.&nbsp;It&#39;s &quot;modern&quot;.</a>
      </div>
    </div>
    <div class="result results_links results_links_deep web-result ">
      <div class="links_main links_deep result__body">
        <h2 class="result__title"><a class="result__a" rel="nofollow" href="https://example.com/direct">Direct link</a></h2>
      </div>
    </div>
    </body></html>
    """

    @Test func parsesDuckDuckGoResults() throws {
        let results = try DuckDuckGoHTMLClient.parse(Data(page.utf8))
        #expect(results.count == 2, "The ad is skipped")
        #expect(results[0].url == "https://www.swift.org/about/?a=1&b=2")
        #expect(results[0].title == "About Swift & more")
        #expect(results[0].snippet == "Swift is a general-purpose language \u{2014} fast & safe. It's \"modern\".")
        #expect(results[1].url == "https://example.com/direct")
        #expect(results[1].snippet.isEmpty)
    }

    @Test func detectsTheBotCheck() {
        let html = #"<html><body><div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div></body></html>"#
        #expect {
            try DuckDuckGoHTMLClient.parse(Data(html.utf8))
        } throws: { error in
            guard case ChatProviderError.unavailable(let reason) = error else { return false }
            return reason == DuckDuckGoHTMLClient.rateLimitedReason
        }
    }

    @Test func unwrapsRedirectLinks() {
        #expect(DuckDuckGoHTMLClient.resultURL("//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.example%2Fb&amp;rut=1") == "https://a.example/b")
        #expect(DuckDuckGoHTMLClient.resultURL("https://duckduckgo.com/y.js?ad=1") == nil)
        #expect(DuckDuckGoHTMLClient.resultURL("/relative") == nil)
    }

    @Test func emptyPageHasNoResults() throws {
        #expect(try DuckDuckGoHTMLClient.parse(Data("<html><body>No results.</body></html>".utf8)).isEmpty)
    }

    // MARK: - Instant Answer

    @Test func decodesInstantAnswers() throws {
        let json = """
        {
          "Answer": "",
          "Heading": "Swift (programming language)",
          "AbstractText": "Swift is a  general-purpose language.",
          "AbstractURL": "https://en.wikipedia.org/wiki/Swift_(programming_language)",
          "Definition": "",
          "RelatedTopics": [
            {"FirstURL": "https://duckduckgo.com/Objective-C", "Text": "Objective-C - A language Swift replaced."},
            {"Name": "See also", "Topics": [
              {"FirstURL": "https://duckduckgo.com/Xcode", "Text": "Xcode"}
            ]},
            {"FirstURL": "", "Text": "No link"}
          ]
        }
        """
        let results = try DuckDuckGoInstantAnswerClient.decode(Data(json.utf8), query: "swift")
        #expect(results.map(\.url) == [
            "https://en.wikipedia.org/wiki/Swift_(programming_language)",
            "https://duckduckgo.com/Objective-C",
            "https://duckduckgo.com/Xcode"
        ])
        #expect(results[0].title == "Swift (programming language)")
        #expect(results[0].snippet == "Swift is a general-purpose language.")
        #expect(results[1].title == "Objective-C")
        #expect(results[2].title == "Xcode")
    }

    @Test func instantAnswerComesFirst() throws {
        let json = """
        {"Answer": "42", "Definition": "A number.", "DefinitionURL": "https://dict.example/42",
         "DefinitionSource": "Dict", "AbstractText": "", "RelatedTopics": []}
        """
        let results = try DuckDuckGoInstantAnswerClient.decode(Data(json.utf8), query: "6 * 7")
        #expect(results.count == 2)
        #expect(results[0].snippet == "42")
        #expect(results[0].url == DuckDuckGoInstantAnswerClient.answerURL(for: "6 * 7"))
        #expect(results[1].title == "Dict")
    }

    @Test func toleratesAnswerObjects() throws {
        let json = #"{"Answer": {"from": "calculator"}, "RelatedTopics": []}"#
        #expect(try DuckDuckGoInstantAnswerClient.decode(Data(json.utf8), query: "x").isEmpty)
    }

    // MARK: - Wikipedia

    @Test func decodesWikipediaResults() throws {
        let json = """
        {"query": {"search": [
          {"title": "Swift (programming language)",
           "snippet": "<span class=\\"searchmatch\\">Swift</span>'s design &quot;safe&quot;"}
        ]}}
        """
        let results = try WikipediaSearchClient.decode(Data(json.utf8), language: "de")
        #expect(results == [SearchResult(
            title: "Swift (programming language)",
            url: "https://de.wikipedia.org/wiki/Swift_(programming_language)",
            snippet: "Swift's design \"safe\""
        )])
    }

    @Test func encodesArticleURLs() {
        #expect(WikipediaSearchClient.articleURL(title: "AC/DC", language: "en") == "https://en.wikipedia.org/wiki/AC/DC")
        #expect(WikipediaSearchClient.articleURL(title: "What? 100%", language: "en") == "https://en.wikipedia.org/wiki/What%3F_100%25")
        #expect(WikipediaSearchClient.articleURL(title: "Zürich", language: "de") == "https://de.wikipedia.org/wiki/Z%C3%BCrich")
    }

    // MARK: - Merging

    @Test func mergesInSourceOrderWithoutDuplicates() async throws {
        let client = OnDeviceSearchClient(sources: [
            // The slowest source still comes first.
            FakeSource(results: [result("https://a")], delay: .milliseconds(50)),
            FakeSource(results: [result("https://b"), result("https://a", "dup"), result("https://c")]),
            FakeSource(results: [result("https://d")])
        ])
        let results = try await client.search("q", limit: 3)
        #expect(results.map(\.url) == ["https://a", "https://b", "https://c"])
        #expect(results[0].title == "T")
    }

    @Test func partialFailureKeepsWhatWorked() async throws {
        let client = OnDeviceSearchClient(sources: [
            FakeSource(error: ChatProviderError.invalidResponse),
            FakeSource(results: [result("https://b")])
        ])
        #expect(try await client.search("q", limit: 5).map(\.url) == ["https://b"])
    }

    @Test func emptyResultsAreNotAnError() async throws {
        let client = OnDeviceSearchClient(sources: [FakeSource(), FakeSource()])
        #expect(try await client.search("q", limit: 5).isEmpty)
    }

    @Test func nothingFoundWithAFailureReportsTheFailure() async {
        // DuckDuckGo's bot check while the others find nothing shouldn't
        // look like an empty search.
        let client = OnDeviceSearchClient(sources: [
            FakeSource(),
            FakeSource(error: ChatProviderError.unavailable(reason: DuckDuckGoHTMLClient.rateLimitedReason))
        ])
        await #expect {
            try await client.search("q", limit: 5)
        } throws: { error in
            guard case ChatProviderError.unavailable(let reason) = error else { return false }
            return reason == DuckDuckGoHTMLClient.rateLimitedReason
        }
    }

    @Test func throwsTheFirstErrorWhenEverySourceFails() async {
        let client = OnDeviceSearchClient(sources: [
            FakeSource(error: ChatProviderError.unavailable(reason: "first"), delay: .milliseconds(30)),
            FakeSource(error: ChatProviderError.unavailable(reason: "second"))
        ])
        await #expect {
            try await client.search("q", limit: 5)
        } throws: { error in
            guard case ChatProviderError.unavailable(let reason) = error else { return false }
            return reason == "first"
        }
    }

    // MARK: - HTML text

    @Test func plainTextFromHTML() {
        #expect(HTMLText.plain("a<br>b <b>c</b>d &lt;e&gt; &#65;&#x42; &unknown;") == "a b cd <e> AB &unknown;")
    }
}
