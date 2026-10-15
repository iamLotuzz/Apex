import Foundation
import CoreLocation

enum FuelType: String, CaseIterable, Codable, Identifiable {
    case e5, e10, diesel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .e5: return "Super E5"
        case .e10: return "Super E10"
        case .diesel: return "Diesel"
        }
    }

    var shortTitle: String {
        switch self {
        case .e5: return "E5"
        case .e10: return "E10"
        case .diesel: return "Diesel"
        }
    }

    /// kg CO₂ per litre burned.
    var co2PerLitre: Double {
        self == .diesel ? 2.65 : 2.37
    }
}

struct FuelStation: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var brand: String
    var street: String
    var houseNumber: String
    var place: String
    var lat: Double
    var lng: Double
    var dist: Double
    var price: Double
    var isOpen: Bool
    /// Driving distance by road in km (nil until routed).
    var roadKm: Double? = nil
    /// Driving time in seconds (nil until routed).
    var driveSeconds: Double? = nil

    /// Road distance when known, otherwise the straight-line distance.
    var shownKm: Double { roadKm ?? dist }

    /// "3,4 km · 6 Min." by road, or "≈ 2,1 km" straight-line.
    var distanceText: String {
        let km = shownKm.formatted(.number.precision(.fractionLength(1)))
        guard roadKm != nil else { return "≈ \(km) km" }
        if let seconds = driveSeconds {
            return "\(km) km · \(max(1, Int((seconds / 60).rounded()))) Min."
        }
        return "\(km) km"
    }

    var displayName: String {
        let trimmed = brand.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name.capitalized : trimmed
    }

    var address: String {
        let street = [self.street.capitalized, houseNumber].filter { !$0.isEmpty }.joined(separator: " ")
        return [street, place.capitalized].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// Opens Apex and starts navigation to this station.
    var navigationURL: URL {
        var components = URLComponents()
        components.scheme = "apex"
        components.host = "navigate"
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lng", value: String(lng)),
            URLQueryItem(name: "name", value: displayName)
        ]
        return components.url ?? URL(string: "apex://garage")!
    }
}

enum FuelAPIError: LocalizedError {
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .invalidResponse: return "Ungültige Antwort von Tankerkönig."
        }
    }
}

/// Client for the Tankerkönig API (data from the MTS-K, licence CC BY 4.0).
enum FuelAPI {
    static let demoKey = "00000000-0000-0000-0000-000000000002"
    static let signupURL = URL(string: "https://creativecommons.tankerkoenig.de")!

    static func stations(
        near coordinate: CLLocationCoordinate2D,
        radiusKm: Double,
        fuel: FuelType,
        apiKey: String
    ) async throws -> [FuelStation] {
        var components = URLComponents(string: "https://creativecommons.tankerkoenig.de/json/list.php")!
        let radius = min(max(radiusKm, 1), 25)
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.5f", coordinate.latitude)),
            URLQueryItem(name: "lng", value: String(format: "%.5f", coordinate.longitude)),
            URLQueryItem(name: "rad", value: String(format: "%.0f", radius)),
            URLQueryItem(name: "sort", value: "price"),
            URLQueryItem(name: "type", value: fuel.rawValue),
            URLQueryItem(name: "apikey", value: apiKey)
        ]
        guard let url = components.url else { throw FuelAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(ListResponse.self, from: data)
        guard response.ok else {
            throw FuelAPIError.server(response.message ?? "Tankerkönig meldet einen Fehler.")
        }
        let stations = (response.stations ?? []).compactMap { $0.station }
        return stations
            .filter { $0.isOpen && $0.price > 0.5 }
            .sorted { ($0.price, $0.dist) < ($1.price, $1.dist) }
    }

    private struct ListResponse: Decodable {
        let ok: Bool
        let message: String?
        let stations: [RawStation]?
    }

    /// Decodes leniently: Tankerkönig sends `false` or `null` for missing prices
    /// and numbers or strings for some fields.
    private struct RawStation: Decodable {
        let station: FuelStation?

        enum CodingKeys: String, CodingKey {
            case id, name, brand, street, houseNumber, place, lat, lng, dist, price, isOpen
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func string(_ key: CodingKeys) -> String {
                if let s = try? c.decode(String.self, forKey: key) { return s }
                if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
                return ""
            }
            func double(_ key: CodingKeys) -> Double? {
                if let d = try? c.decode(Double.self, forKey: key) { return d }
                if let s = try? c.decode(String.self, forKey: key) { return Double(s) }
                return nil
            }
            let id = string(.id)
            guard !id.isEmpty, let lat = double(.lat), let lng = double(.lng), let price = double(.price) else {
                station = nil
                return
            }
            let isOpen = (try? c.decode(Bool.self, forKey: .isOpen)) ?? true
            station = FuelStation(
                id: id,
                name: string(.name),
                brand: string(.brand),
                street: string(.street),
                houseNumber: string(.houseNumber).trimmingCharacters(in: .whitespaces),
                place: string(.place),
                lat: lat,
                lng: lng,
                dist: double(.dist) ?? 0,
                price: price,
                isOpen: isOpen
            )
        }
    }
}

enum PriceFormat {
    /// Splits 1.729 into ("1,72", "9") like a German price board.
    static func parts(_ price: Double) -> (main: String, last: String) {
        let thousandths = Int((price * 1000).rounded())
        let euros = thousandths / 1000
        let cents = (thousandths % 1000) / 10
        let last = thousandths % 10
        let separator = Locale.current.decimalSeparator ?? ","
        return ("\(euros)\(separator)\(String(format: "%02d", cents))", "\(last)")
    }
}
