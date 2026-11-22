import Foundation
import Testing
import os
@testable import Madrigal

/// Returns canned page text, keyed by URL.
private struct FakePageReader: WebPageReading {
    var pages: [String: String]
    func text(of url: URL) async -> String? { pages[url.absoluteString] }
}

private struct FakeWeather: WeatherLookup {
    var result: SearchResult?
    func forecast(for query: String) async -> SearchResult? { result }
}

private struct FixedSearch: WebSearchClient {
    var results: [SearchResult] = []
    var error: Error?
    func search(_ query: String, limit: Int) async throws -> [SearchResult] {
        if let error { throw error }
        return results
    }
}

struct WebPageAndWeatherTests {

    // MARK: - Page text

    @Test(arguments: [
        ("https://example.com/a", true),
        ("http://example.com/a", true),
        ("http://192.168.1.1/admin", false),
        ("http://10.0.0.5/", false),
        ("http://localhost:8080/", false),
        ("http://router.local/", false),
        ("http://intranet/", false),
        ("http://[::1]/", false),
        ("file:///etc/passwd", false),
        ("ftp://example.com/", false),
    ])
    func pageReaderOnlyFetchesPublicWebPages(url: String, allowed: Bool) throws {
        #expect(try #require(URL(string: url)).isPublicWebPage == allowed)
    }

    @Test(arguments: [
        ("https://example.com", true),
        ("HTTP://example.com", true),
        ("mailto:a@example.com", true),
        ("tel:+15555550100", false),
        ("sms:+15555550100", false),
        ("shortcuts://run-shortcut?name=x", false),
        ("javascript:alert(1)", false),
    ])
    func onlyWebAndMailLinksOpen(url: String, allowed: Bool) throws {
        #expect(try #require(URL(string: url)).isSafeToOpen == allowed)
    }

    @Test func pageReaderRefusesLocalHostsWithoutFetching() async throws {
        let reader = WebPageReader()
        #expect(await reader.text(of: try #require(URL(string: "http://192.168.1.1/"))) == nil)
    }

    @Test func pageTextKeepsContentAndDropsChrome() {
        let html = """
        <html><head><title>T</title><style>p{color:red}</style></head><body>
        <nav><a href="/">Home</a> <a href="/x">Menu</a></nav>
        <script>var x = "<p>not text</p>";</script>
        <!-- a comment -->
        <h1>Seattle weather</h1><p>Today: <b>54</b>&deg;F and cloudy &amp; damp.</p>
        <div>Tomorrow: rain</div>
        <footer>Copyright</footer>
        </body></html>
        """
        #expect(HTMLText.lines(html) == "Seattle weather\nToday: 54°F and cloudy & damp.\nTomorrow: rain")
    }

    @Test func excerptPrefersPartsMatchingTheQuery() {
        let filler = String(repeating: "Subscribe to our newsletter for deals. ", count: 10)
        let text = [filler, "Seattle forecast: high 55, low 46, rain likely Saturday.", filler, "Unrelated footer text."].joined(separator: "\n")
        let excerpt = PageText.excerpt(from: text, query: "what's the weather in Seattle this weekend", budget: 200)
        #expect(excerpt.contains("high 55"))
        #expect(!excerpt.contains("newsletter"))
        #expect(excerpt.count <= 200)
    }

    @Test func excerptFallsBackToTheStartAndFitsTheBudget() {
        let text = (1...50).map { "Line \($0) about nothing much at all here." }.joined(separator: "\n")
        let excerpt = PageText.excerpt(from: text, query: "zebra", budget: 120)
        #expect(excerpt.hasPrefix("Line 1 "))
        #expect(excerpt.count <= 120)
        #expect(PageText.excerpt(from: text, query: "zebra", budget: 0).isEmpty)
    }

    @Test func keywordsSkipCommonWords() {
        #expect(PageText.keywords(in: "What's the weather like in Seattle?") == ["weather", "seattle"])
    }

    // MARK: - Weather questions

    @Test(arguments: [
        ("What's the weather in Seattle?", "Seattle"),
        ("weather in New York this weekend", "New York"),
        ("Will it rain in Paris tomorrow", "Paris"),
        ("whats the weather like in Portland, Maine today?", "Portland, Maine"),
        ("Tokyo weather", "Tokyo"),
        ("london forecast for next week", "london"),
        ("temperature in San Francisco right now", "San Francisco")
    ])
    func findsThePlace(query: String, place: String) {
        #expect(OpenMeteoWeather.place(in: query) == place)
    }

    @Test(arguments: [
        "What's the weather?",
        "How's the weather today",
        "Is it going to snow",
        "Who won the World Series?",
        "Train times to Seattle"
    ])
    func ignoresQuestionsWithoutAPlaceOrWeather(query: String) {
        #expect(OpenMeteoWeather.place(in: query) == nil)
    }

    @Test func prefersTheNamedRegion() {
        let json = #"""
        {"results":[
          {"name":"Portland","latitude":45.5,"longitude":-122.7,"country":"United States","country_code":"US","admin1":"Oregon"},
          {"name":"Portland","latitude":43.7,"longitude":-70.3,"country":"United States","country_code":"US","admin1":"Maine"}
        ]}
        """#
        let data = Data(json.utf8)
        #expect(OpenMeteoWeather.bestMatch(data, for: "Portland, Maine")?.admin1 == "Maine")
        #expect(OpenMeteoWeather.bestMatch(data, for: "Portland")?.admin1 == "Oregon")
        #expect(OpenMeteoWeather.bestMatch(data, for: "Portland")?.displayName == "Portland, Oregon, United States")
        #expect(OpenMeteoWeather.bestMatch(Data(#"{"generationtime_ms":0.5}"#.utf8), for: "Nowhere") == nil)
    }

    @Test func describesTheForecast() throws {
        let json = #"""
        {"current":{"time":"2026-11-02T14:15","temperature_2m":54.4,"apparent_temperature":51.2,
          "relative_humidity_2m":70,"weather_code":2,"wind_speed_10m":8.3,"precipitation":0},
         "daily":{"time":["2026-11-02","2026-11-03"],"weather_code":[61,null],
          "temperature_2m_max":[55.1,57.8],"temperature_2m_min":[45.6,null],
          "precipitation_probability_max":[80,null]}}
        """#
        let text = try #require(OpenMeteoWeather.describe(Data(json.utf8), usesUSUnits: true))
        #expect(text == """
        Now (2:15 PM local time): Partly cloudy, 54°F, feels like 51°F, humidity 70%, wind 8 mph
        Mon Nov 2: Light rain, high 55°F, low 46°F, 80% chance of precipitation
        Tue Nov 3: high 58°F
        """)
        #expect(OpenMeteoWeather.describe(Data("{}".utf8), usesUSUnits: false) == nil)
    }

    // MARK: - Searching with pages and weather

    private let results = [
        SearchResult(title: "Seattle weather", url: "https://weather.example/seattle", snippet: "Get the latest forecast."),
        SearchResult(title: "Other", url: "https://other.example/", snippet: "Something else.")
    ]

    private func config(search: FixedSearch, pages: [String: String] = [:], weather: SearchResult? = nil) -> WebSearchConfig {
        var config = WebSearchConfig(mode: .always, client: search, characterCap: 2_000)
        config.pageReader = FakePageReader(pages: pages)
        config.pagesToRead = 2
        config.weather = FakeWeather(result: weather)
        config.isOnline = { true }
        return config
    }

    @Test func resultsIncludeWhatThePagesSay() async {
        let config = config(
            search: FixedSearch(results: results),
            pages: ["https://weather.example/seattle": "Menu\nSeattle tomorrow: high 55, low 46, light rain."]
        )
        let statuses = StatusLog()
        let outcome = await config.run("Seattle weather tomorrow") { statuses.append($0.status) }
        #expect(outcome.text.contains("From the page: Menu Seattle tomorrow: high 55, low 46, light rain."))
        #expect(outcome.text.contains("[2] Other"))
        #expect(statuses.values.contains(WebSearchConfig.readingStatusText(pageCount: 2)))
        #expect(outcome.record?.results == results)
    }

    @Test func forecastComesFirstAndSkipsPageReading() async {
        let forecast = SearchResult(title: "Weather forecast for Seattle", url: OpenMeteoWeather.sourceURL, snippet: "Now: Rain, 50°F")
        let config = config(
            search: FixedSearch(results: results),
            pages: ["https://weather.example/seattle": "Should not be read."],
            weather: forecast
        )
        let outcome = await config.run("weather in Seattle")
        #expect(outcome.text.hasPrefix("[1] Weather forecast for Seattle"))
        #expect(outcome.text.contains("Now: Rain, 50°F"))
        #expect(!outcome.text.contains("Should not be read"))
        #expect(outcome.record?.results.first == forecast)
    }

    @Test func forecastStillAnswersWhenTheSearchFails() async {
        let forecast = SearchResult(title: "Weather forecast for Oslo", url: OpenMeteoWeather.sourceURL, snippet: "Now: Snow, -2°C")
        let config = config(search: FixedSearch(error: ChatProviderError.invalidResponse), weather: forecast)
        let outcome = await config.run("Oslo weather")
        #expect(outcome.record == WebSearchRecord(query: "Oslo weather", results: [forecast]))
    }

    @Test func instructionsAskForAnAnswerNotLinks() {
        let record = WebSearchRecord(query: "q", results: results)
        #expect(WebSearchConfig.instructions(for: record, formatted: "").contains("Don't just list the links"))
    }
}

/// Collects the statuses a search reports.
private final class StatusLog: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String]())
    var values: [String] { lock.withLock { $0 } }
    func append(_ value: String) { lock.withLock { $0.append(value) } }
}
