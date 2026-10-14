import Foundation
import CoreLocation
import SwiftUI

struct HourForecast: Identifiable {
    var date: Date
    var temperature: Double
    var precipitationProbability: Int
    var code: Int

    var id: Date { date }
}

struct WeatherSnapshot {
    var temperature: Double
    var apparentTemperature: Double
    var humidity: Double
    var precipitation: Double
    var snowfall: Double
    var code: Int
    var cloudCover: Double
    var windSpeed: Double
    var windGusts: Double
    var visibility: Double?
    var isDay: Bool
    var sunrise: Date?
    var sunset: Date?
    var hours: [HourForecast]
    var fetchedAt: Date

    var condition: WeatherCondition { WeatherCondition(code: code, isDay: isDay) }
}

/// Weather from Open-Meteo (no key needed, CC BY 4.0).
enum WeatherService {
    static func fetch(_ coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,snowfall,weather_code,cloud_cover,wind_speed_10m,wind_gusts_10m,visibility,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh")
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let current = response.current else { throw URLError(.cannotParseResponse) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: response.utc_offset_seconds ?? 0)

        var hours: [HourForecast] = []
        if let hourly = response.hourly {
            let now = Date().addingTimeInterval(-3600)
            for (i, time) in hourly.time.enumerated() {
                guard let date = formatter.date(from: time), date >= now else { continue }
                let temp = hourly.temperature_2m[safe: i] ?? nil
                let prob = hourly.precipitation_probability?[safe: i] ?? nil
                let code = hourly.weather_code[safe: i] ?? nil
                hours.append(HourForecast(
                    date: date,
                    temperature: temp ?? 0,
                    precipitationProbability: prob ?? 0,
                    code: code ?? 0
                ))
                if hours.count >= 13 { break }
            }
        }

        let sunrise = response.daily?.sunrise.first.flatMap { formatter.date(from: $0) }
        let sunset = response.daily?.sunset.first.flatMap { formatter.date(from: $0) }

        return WeatherSnapshot(
            temperature: current.temperature_2m ?? 0,
            apparentTemperature: current.apparent_temperature ?? current.temperature_2m ?? 0,
            humidity: current.relative_humidity_2m ?? 0,
            precipitation: current.precipitation ?? 0,
            snowfall: current.snowfall ?? 0,
            code: current.weather_code ?? 0,
            cloudCover: current.cloud_cover ?? 0,
            windSpeed: current.wind_speed_10m ?? 0,
            windGusts: current.wind_gusts_10m ?? 0,
            visibility: current.visibility,
            isDay: (current.is_day ?? 1) == 1,
            sunrise: sunrise,
            sunset: sunset,
            hours: hours,
            fetchedAt: Date()
        )
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double?
            let apparent_temperature: Double?
            let relative_humidity_2m: Double?
            let precipitation: Double?
            let snowfall: Double?
            let weather_code: Int?
            let cloud_cover: Double?
            let wind_speed_10m: Double?
            let wind_gusts_10m: Double?
            let visibility: Double?
            let is_day: Int?
        }

        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let precipitation_probability: [Int?]?
            let weather_code: [Int?]
        }

        struct Daily: Decodable {
            let sunrise: [String]
            let sunset: [String]
        }

        let utc_offset_seconds: Int?
        let current: Current?
        let hourly: Hourly?
        let daily: Daily?
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// WMO weather codes mapped to German text and SF Symbols.
struct WeatherCondition {
    let code: Int
    let isDay: Bool

    var text: String {
        switch code {
        case 0: return isDay ? "Sonnig" : "Klar"
        case 1: return "Überwiegend klar"
        case 2: return "Teilweise bewölkt"
        case 3: return "Bedeckt"
        case 45, 48: return "Nebel"
        case 51, 53, 55: return "Nieselregen"
        case 56, 57: return "Gefrierender Niesel"
        case 61: return "Leichter Regen"
        case 63: return "Regen"
        case 65: return "Starker Regen"
        case 66, 67: return "Gefrierender Regen"
        case 71, 73, 75, 77: return "Schneefall"
        case 80, 81: return "Regenschauer"
        case 82: return "Heftige Schauer"
        case 85, 86: return "Schneeschauer"
        case 95: return "Gewitter"
        case 96, 99: return "Gewitter mit Hagel"
        default: return "Unbekannt"
        }
    }

    var symbol: String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82, 66, 67: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    var isRain: Bool { [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99].contains(code) }
    var isHeavyRain: Bool { [65, 67, 82, 95, 96, 99].contains(code) }
    var isSnow: Bool { [71, 73, 75, 77, 85, 86].contains(code) }
    var isFreezing: Bool { [56, 57, 66, 67].contains(code) }
    var isFog: Bool { code == 45 || code == 48 }
    var isThunder: Bool { code >= 95 }
}

/// A plain-language rating of how good it is to drive right now.
struct DrivingConditions {
    enum Level: Int {
        case good, caution, bad

        var color: Color {
            switch self {
            case .good: return .green
            case .caution: return .orange
            case .bad: return .red
            }
        }

        var symbol: String {
            switch self {
            case .good: return "checkmark.seal.fill"
            case .caution: return "exclamationmark.triangle.fill"
            case .bad: return "xmark.octagon.fill"
            }
        }
    }

    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        let level: Level

        var id: String { title }
    }

    let level: Level
    let headline: String
    let grip: Int
    let items: [Item]

    init(weather w: WeatherSnapshot) {
        var items: [Item] = []
        var grip = 100
        let c = w.condition

        if c.isFreezing || (w.temperature <= 3 && (w.precipitation > 0 || c.isRain || c.isSnow || w.humidity >= 92)) {
            items.append(Item(symbol: "snowflake", title: "Glättegefahr", detail: "Um den Gefrierpunkt mit Feuchtigkeit: Brücken und Schattenstellen können glatt sein.", level: .bad))
            grip -= 60
        } else if w.temperature <= 3 {
            items.append(Item(symbol: "thermometer.snowflake", title: "Kalte Fahrbahn", detail: "Reifen brauchen länger, bis sie Grip aufbauen.", level: .caution))
            grip -= 15
        }

        if c.isSnow || w.snowfall > 0 {
            items.append(Item(symbol: "cloud.snow.fill", title: "Schnee", detail: "Schneefall – Abstand vergrößern, Winterreifen Pflicht.", level: .bad))
            grip -= 45
        }

        if c.isThunder {
            items.append(Item(symbol: "cloud.bolt.rain.fill", title: "Gewitter", detail: "Starkregen und Sturmböen möglich.", level: .bad))
            grip -= 35
        } else if c.isHeavyRain || w.precipitation >= 4 {
            items.append(Item(symbol: "cloud.heavyrain.fill", title: "Starkregen", detail: "Aquaplaning-Gefahr. Tempo deutlich reduzieren.", level: .bad))
            grip -= 40
        } else if c.isRain || w.precipitation > 0.1 {
            items.append(Item(symbol: "cloud.rain.fill", title: "Nasse Fahrbahn", detail: "Längerer Bremsweg, weniger Grip in Kurven.", level: .caution))
            grip -= 25
        }

        if let visibility = w.visibility, visibility < 1000 || c.isFog {
            let bad = visibility < 200
            items.append(Item(symbol: "cloud.fog.fill", title: "Nebel", detail: "Sicht etwa \(Fmt.distance(visibility)). Licht an.", level: bad ? .bad : .caution))
            grip -= bad ? 15 : 5
        } else if c.isFog {
            items.append(Item(symbol: "cloud.fog.fill", title: "Nebel", detail: "Eingeschränkte Sicht. Licht an.", level: .caution))
            grip -= 5
        }

        if w.windGusts >= 75 {
            items.append(Item(symbol: "wind", title: "Sturmböen", detail: "Böen bis \(Int(w.windGusts)) km/h – besonders auf Brücken.", level: .bad))
            grip -= 10
        } else if w.windGusts >= 50 {
            items.append(Item(symbol: "wind", title: "Starker Wind", detail: "Böen bis \(Int(w.windGusts)) km/h.", level: .caution))
            grip -= 5
        }

        if !w.isDay {
            items.append(Item(symbol: "moon.fill", title: "Dunkelheit", detail: "Wildwechsel beachten, besonders auf Landstraßen.", level: .caution))
        }

        if w.temperature < 7 && !items.contains(where: { $0.title == "Glättegefahr" }) {
            items.append(Item(symbol: "circle.circle", title: "Winterreifen-Wetter", detail: "Unter 7 °C haben Winterreifen mehr Grip als Sommerreifen.", level: .good))
        }

        if items.isEmpty || items.allSatisfy({ $0.level == .good }) {
            items.insert(Item(symbol: "checkmark.seal.fill", title: "Trockene Straßen", detail: "Gute Bedingungen für eine Ausfahrt.", level: .good), at: 0)
        }

        let worst = items.map(\.level.rawValue).max() ?? 0
        let level = Level(rawValue: worst) ?? .good
        let headline: String
        switch level {
        case .good:
            let perfect = w.isDay && w.temperature >= 12 && w.temperature <= 28
            headline = perfect ? "Perfektes Fahrwetter" : "Gute Bedingungen"
        case .caution:
            headline = "Vorsichtig fahren"
        case .bad:
            headline = "Schwierige Bedingungen"
        }
        self.level = level
        self.headline = headline
        self.grip = max(0, min(100, grip))
        self.items = items
    }
}
