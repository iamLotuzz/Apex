import Foundation
import CoreLocation
import Observation

/// Current speed limit from OpenStreetMap (Overpass API). Apple does not
/// share speed limits with other apps.
///
/// Roads with a `maxspeed` tag within 80 m are loaded every ~150 m or
/// 30 s; each fix then picks the nearest road that runs in the driving
/// direction, so the limit changes right at the sign without waiting for
/// the network.
@MainActor
@Observable
final class SpeedLimitService {
    static let shared = SpeedLimitService()

    /// km/h; 0 means no limit (German motorway); nil means unknown.
    private(set) var limit: Int?

    private struct Way {
        let points: [CLLocationCoordinate2D]
        let forward: Int?
        let backward: Int?
    }

    @ObservationIgnored private var ways: [Way] = []
    @ObservationIgnored private var lastQuery: CLLocation?
    @ObservationIgnored private var lastQueryDate = Date.distantPast
    @ObservationIgnored private var loading = false

    func reset() {
        ways = []
        limit = nil
        lastQuery = nil
    }

    func update(location: CLLocation, heading: Double) {
        evaluate(location.coordinate, heading: heading)
        let moved = lastQuery.map { location.distance(from: $0) } ?? .infinity
        guard !loading, moved > 150 || Date().timeIntervalSince(lastQueryDate) > 30 else { return }
        loading = true
        lastQuery = location
        lastQueryDate = Date()
        let coordinate = location.coordinate
        Task {
            if let fetched = try? await Self.fetch(around: coordinate) {
                ways = fetched
                evaluate(coordinate, heading: heading)
            }
            loading = false
        }
    }

    private func evaluate(_ c: CLLocationCoordinate2D, heading: Double) {
        let projection = LocalProjection(origin: c)
        var best: (distance: Double, limit: Int?)?
        for way in ways where way.points.count >= 2 {
            for i in 0..<(way.points.count - 1) {
                let a = projection.point(way.points[i])
                let b = projection.point(way.points[i + 1])
                let ab = b - a
                let len2 = ab.dot(ab)
                let u = len2 > 0 ? min(1, max(0, (Vec2(x: 0, y: 0) - a).dot(ab) / len2)) : 0
                let d = (a + ab * u).length
                var bearing = atan2(ab.x, ab.y) * 180 / .pi
                if bearing < 0 { bearing += 360 }
                var diff = abs(bearing - heading)
                if diff > 180 { diff = 360 - diff }
                // Roads crossing the driving direction are a poor match.
                let alignment = min(diff, 180 - diff)
                let score = d + (alignment > 45 ? 40 : 0)
                if score < (best?.distance ?? .infinity) {
                    best = (score, diff <= 90 ? way.forward : way.backward)
                }
            }
        }
        if let best, best.distance < 35 {
            limit = best.limit
        } else if best == nil || (best?.distance ?? 0) > 60 {
            limit = nil
        }
    }

    // MARK: Overpass

    private static func fetch(around c: CLLocationCoordinate2D) async throws -> [Way] {
        let query = "[out:json][timeout:10];way(around:80,\(c.latitude),\(c.longitude))[highway][maxspeed];out tags geom;"
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.elements.compactMap { element in
            guard let geometry = element.geometry, let tags = element.tags else { return nil }
            let general = parse(tags["maxspeed"])
            let forward = parse(tags["maxspeed:forward"]) ?? general
            let backward = parse(tags["maxspeed:backward"]) ?? general
            guard forward != nil || backward != nil else { return nil }
            return Way(
                points: geometry.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                forward: forward,
                backward: backward
            )
        }
    }

    /// "50", "30 mph", "DE:urban", "none" … → km/h (0 = no limit).
    static func parse(_ value: String?) -> Int? {
        guard let raw = value?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw == "none" || raw.hasSuffix(":motorway") { return 0 }
        if raw.hasSuffix(":urban") { return 50 }
        if raw.hasSuffix(":rural") { return 100 }
        if raw.contains("living_street") || raw == "walk" { return 7 }
        if raw.contains("zone30") || raw.contains("zone:30") { return 30 }
        if raw.contains("zone20") || raw.contains("zone:20") { return 20 }
        let digits = raw.prefix { $0.isNumber }
        guard let number = Int(digits), number > 0 else { return nil }
        return raw.contains("mph") ? Int((Double(number) * 1.609).rounded()) : number
    }

    private struct Response: Decodable {
        struct Point: Decodable {
            let lat: Double
            let lon: Double
        }

        struct Element: Decodable {
            let tags: [String: String]?
            let geometry: [Point]?
        }

        let elements: [Element]
    }
}
