import Foundation

/// Answers weather questions with a real forecast, since search snippets
/// for weather rarely include the numbers.
protocol WeatherLookup: Sendable {
    /// A forecast as a search result, or nil when the query isn't about
    /// the weather somewhere or the lookup failed.
    func forecast(for query: String) async -> SearchResult?
}

/// Open-Meteo's free forecast and geocoding APIs. No key or account; it
/// sees the place name and the device's IP address.
struct OpenMeteoWeather: WeatherLookup {
    var session: URLSession = .shared
    var usesUSUnits: Bool = Locale.current.measurementSystem == .us
    var language: String = Locale.apiLanguageCode

    static let sourceURL = "https://open-meteo.com/"

    func forecast(for query: String) async -> SearchResult? {
        guard let place = Self.place(in: query),
              let location = await geocode(place),
              let forecast = await fetchForecast(at: location) else { return nil }
        return SearchResult(
            title: "Weather forecast for \(location.displayName) (Open-Meteo)",
            url: Self.sourceURL,
            snippet: forecast
        )
    }

    // MARK: - Finding the place

    private static let weatherWord = #"(?:weather|forecast|temperature|rain|raining|snow|snowing|sunny|humid|humidity|windy)"#
    /// "weather in Seattle tomorrow", "will it rain in Paris?"
    private static let placeAfter = try! NSRegularExpression(
        pattern: "\\b\(weatherWord)\\b.*?\\b(?:in|for|at|near|around)\\s+(.+)$",
        options: [.caseInsensitive]
    )
    /// "Seattle weather", "Tokyo forecast this week"
    private static let placeBefore = try! NSRegularExpression(
        pattern: "^(.+?)\\s+\(weatherWord)\\b",
        options: [.caseInsensitive]
    )
    /// Where the place name ends: when-words and trailing phrases.
    private static let placeEnd = try! NSRegularExpression(
        pattern: "(?:^|\\s+)(?:today|tonight|tomorrow|this|next|now|right now|currently|on|over|during|later|in the|for the|at the|like|be|look|going|by|until|through|from|monday|tuesday|wednesday|thursday|friday|saturday|sunday|weekend|week)\\b.*$|[?!.]+.*$",
        options: [.caseInsensitive]
    )
    private static let leadingFiller: Set<String> = [
        "what", "what's", "whats", "how", "how's", "hows", "is", "will", "the", "today's", "tomorrow's",
        "current", "local", "my", "a", "it", "does", "do", "check", "tell", "me", "get", "show"
    ]

    /// The place a weather question asks about, or nil when there's no
    /// weather word or no place.
    static func place(in query: String) -> String? {
        let text = SearchText.collapse(query)
        let range = NSRange(location: 0, length: (text as NSString).length)
        // "London forecast for next week" has no place after "for".
        for pattern in [placeAfter, placeBefore] {
            if let match = pattern.firstMatch(in: text, range: range),
               let place = cleanPlace((text as NSString).substring(with: match.range(at: 1))) {
                return place
            }
        }
        return nil
    }

    /// The place without when-words, filler, or punctuation, or nil when
    /// nothing like a place is left.
    private static func cleanPlace(_ captured: String) -> String? {
        var place = captured
        place = placeEnd.stringByReplacingMatches(
            in: place, range: NSRange(location: 0, length: (place as NSString).length), withTemplate: ""
        )
        var words = place.split(separator: " ").map(String.init)
        while let first = words.first, leadingFiller.contains(first.lowercased()) { words.removeFirst() }
        place = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:'\""))
        guard !place.isEmpty, place.count <= 60, words.count <= 6,
              !leadingFiller.contains(place.lowercased()) else { return nil }
        return place
    }

    // MARK: - Geocoding

    struct Location: Decodable, Equatable {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let countryCode: String?
        let admin1: String?

        enum CodingKeys: String, CodingKey {
            case name, latitude, longitude, country, admin1
            case countryCode = "country_code"
        }

        var displayName: String {
            [name, admin1, country].compactMap { $0?.nonEmpty }.reduce(into: [String]()) { names, part in
                if names.last != part { names.append(part) }
            }.joined(separator: ", ")
        }
    }

    private struct GeocodingResponse: Decodable {
        let results: [Location]?
    }

    /// "Portland, Maine" searches "Portland" and prefers a result in Maine.
    /// Otherwise the first result, which Open-Meteo ranks by population.
    static func bestMatch(_ data: Data, for place: String) -> Location? {
        guard let results = (try? HTTP.decoder.decode(GeocodingResponse.self, from: data))?.results,
              !results.isEmpty else { return nil }
        let qualifier = place.split(separator: ",", maxSplits: 1).dropFirst().first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !qualifier.isEmpty else { return results.first }
        return results.first { location in
            [location.admin1, location.country].contains { $0?.lowercased().hasPrefix(qualifier) == true }
                || location.countryCode?.lowercased() == qualifier
        } ?? results.first
    }

    private func geocode(_ place: String) async -> Location? {
        let name = place.split(separator: ",").first.map(String.init) ?? place
        guard let url = try? URL.api("https://geocoding-api.open-meteo.com/v1/search", query: [
            "name": name,
            "count": "5",
            "language": language,
            "format": "json"
        ]), let data = await fetch(url) else { return nil }
        return Self.bestMatch(data, for: place)
    }

    // MARK: - Forecast

    private func fetchForecast(at location: Location) async -> String? {
        // Celsius, km/h and millimetres are Open-Meteo's defaults.
        guard let url = try? URL.api("https://api.open-meteo.com/v1/forecast", query: [
            "latitude": String(location.latitude),
            "longitude": String(location.longitude),
            "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,precipitation",
            "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
            "timezone": "auto",
            "forecast_days": "7",
            "temperature_unit": usesUSUnits ? "fahrenheit" : "celsius",
            "wind_speed_unit": usesUSUnits ? "mph" : "kmh",
            "precipitation_unit": usesUSUnits ? "inch" : "mm"
        ]), let data = await fetch(url) else { return nil }
        return Self.describe(data, usesUSUnits: usesUSUnits)
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let time: String?
            let temperature_2m: Double?
            let apparent_temperature: Double?
            let relative_humidity_2m: Double?
            let weather_code: Int?
            let wind_speed_10m: Double?
            let precipitation: Double?
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int?]?
            let temperature_2m_max: [Double?]?
            let temperature_2m_min: [Double?]?
            let precipitation_probability_max: [Int?]?
        }
        let current: Current?
        let daily: Daily?
    }

    /// Current conditions and a line per day, in the place's local time.
    static func describe(_ data: Data, usesUSUnits: Bool) -> String? {
        guard let response = try? HTTP.decoder.decode(ForecastResponse.self, from: data) else { return nil }
        let degrees = usesUSUnits ? "°F" : "°C"
        let speed = usesUSUnits ? "mph" : "km/h"
        let rain = usesUSUnits ? "in" : "mm"
        func temp(_ value: Double?) -> String? { value.map { "\(Int($0.rounded()))\(degrees)" } }

        var lines: [String] = []
        if let current = response.current, let now = temp(current.temperature_2m) {
            var parts = [conditions(current.weather_code), now].compactMap { $0 }
            if let feels = temp(current.apparent_temperature) { parts.append("feels like \(feels)") }
            if let humidity = current.relative_humidity_2m { parts.append("humidity \(Int(humidity.rounded()))%") }
            if let wind = current.wind_speed_10m { parts.append("wind \(Int(wind.rounded())) \(speed)") }
            if let precipitation = current.precipitation, precipitation > 0 { parts.append("precipitation \(precipitation) \(rain)") }
            let when = current.time.flatMap(localTime).map { " (\($0) local time)" } ?? ""
            lines.append("Now\(when): " + parts.joined(separator: ", "))
        }
        if let daily = response.daily {
            for (index, day) in daily.time.enumerated() {
                var parts: [String] = []
                if let summary = conditions(daily.weather_code?[safe: index] ?? nil) { parts.append(summary) }
                if let high = temp(daily.temperature_2m_max?[safe: index] ?? nil) { parts.append("high \(high)") }
                if let low = temp(daily.temperature_2m_min?[safe: index] ?? nil) { parts.append("low \(low)") }
                if let chance = daily.precipitation_probability_max?[safe: index] ?? nil { parts.append("\(chance)% chance of precipitation") }
                guard !parts.isEmpty else { continue }
                lines.append("\(dayName(day) ?? day): " + parts.joined(separator: ", "))
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// WMO weather interpretation codes, as Open-Meteo documents them.
    static func conditions(_ code: Int?) -> String? {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80: return "Light rain showers"
        case 81: return "Rain showers"
        case 82: return "Heavy rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return nil
        }
    }

    // Open-Meteo's times are already local to the place, without a zone,
    // so they're parsed and printed in GMT to leave them unshifted.
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }

    private static let dayParser = formatter("yyyy-MM-dd")
    private static let dayPrinter = formatter("EEE MMM d")
    private static let timeParser = formatter("yyyy-MM-dd'T'HH:mm")
    private static let timePrinter = formatter("h:mm a")

    /// "Sun Nov 2" for "2026-11-02".
    static func dayName(_ day: String) -> String? {
        dayParser.date(from: day).map(dayPrinter.string(from:))
    }

    /// "2:15 PM" for "2026-11-02T14:15".
    static func localTime(_ time: String) -> String? {
        timeParser.date(from: time).map(timePrinter.string(from:))
    }

    private func fetch(_ url: URL) async -> Data? {
        let request = URLRequest(url: url, timeoutInterval: HTTP.weatherTimeout)
        return try? await HTTP.successfulData(for: request, session: session)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
