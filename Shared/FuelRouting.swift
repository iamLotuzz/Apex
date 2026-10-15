import Foundation
import MapKit

/// Turns Tankerkönig's straight-line list into stations you can actually
/// reach by car within the set distance.
///
/// The road is never shorter than the straight line, so every reachable
/// station is already in the list for the same radius. The cheapest ones are
/// routed with Apple's driving directions (ETA requests, a few in parallel)
/// until enough are confirmed within the radius. Results are cached per
/// station and starting point (about 300 m), so the widget and repeated
/// refreshes rarely need new requests.
enum FuelRouting {
    static func reachable(
        _ stations: [FuelStation],
        from origin: CLLocationCoordinate2D,
        radiusKm: Double,
        wanted: Int = 5,
        maxRequests: Int = 14
    ) async -> [FuelStation] {
        let candidates = stations.sorted { ($0.price, $0.dist) < ($1.price, $1.dist) }
        var cache = RouteCache.load()
        var result: [FuelStation] = []
        var requests = 0
        var failures = 0
        var index = 0

        while index < candidates.count && result.count < wanted {
            // Next batch: up to 4 uncached stations routed in parallel.
            var batch: [FuelStation] = []
            while index < candidates.count && batch.count < 4 {
                var station = candidates[index]
                index += 1
                if let hit = cache.lookup(station.id, origin: origin) {
                    station.roadKm = hit.km
                    station.driveSeconds = hit.seconds
                    if hit.km <= radiusKm { result.append(station) }
                    if result.count >= wanted { break }
                } else if requests < maxRequests {
                    batch.append(station)
                    requests += 1
                } else if station.dist * 1.3 <= radiusKm {
                    // Out of request budget: keep a conservative estimate.
                    result.append(station)
                }
            }
            if batch.isEmpty { continue }

            let routed = await withTaskGroup(of: (FuelStation, Double, Double)?.self) { group in
                for station in batch {
                    group.addTask { await eta(to: station, from: origin).map { (station, $0.km, $0.seconds) } }
                }
                var out: [(FuelStation, Double, Double)?] = []
                for await value in group { out.append(value) }
                return out
            }
            for value in routed {
                guard let value else {
                    failures += 1
                    continue
                }
                let (station, km, seconds) = value
                cache.store(station.id, origin: origin, km: km, seconds: seconds)
                if km <= radiusKm {
                    var copy = station
                    copy.roadKm = km
                    copy.driveSeconds = seconds
                    result.append(copy)
                }
            }
            // Offline or rate limited: fall back to straight-line estimates.
            if failures >= 3 && result.isEmpty {
                cache.save()
                return candidates.filter { $0.dist * 1.3 <= radiusKm }
            }
        }
        cache.save()
        return result.sorted { ($0.price, $0.shownKm) < ($1.price, $1.shownKm) }
    }

    private static func eta(to station: FuelStation, from origin: CLLocationCoordinate2D) async -> (km: Double, seconds: Double)? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: station.coordinate))
        request.transportType = .automobile
        request.departureDate = Date()
        guard let response = try? await MKDirections(request: request).calculateETA() else { return nil }
        return (response.distance / 1000, response.expectedTravelTime)
    }
}

extension FuelAPI {
    /// Cheapest open stations reachable by car within `radiusKm` road distance.
    static func reachableStations(
        near coordinate: CLLocationCoordinate2D,
        radiusKm: Double,
        fuel: FuelType,
        apiKey: String,
        maxRequests: Int = 14
    ) async throws -> [FuelStation] {
        let all = try await stations(near: coordinate, radiusKm: radiusKm, fuel: fuel, apiKey: apiKey)
        return await FuelRouting.reachable(all, from: coordinate, radiusKm: radiusKm, maxRequests: maxRequests)
    }
}

/// Road distances per station and rounded starting point, kept for a day.
private struct RouteCache: Codable {
    struct Entry: Codable {
        var km: Double
        var seconds: Double
        var date: Date
    }

    var entries: [String: Entry] = [:]

    private static let key = "fuelRouteCache"

    static func load() -> RouteCache {
        guard let data = SharedStore.defaults.data(forKey: key),
              let cache = try? JSONDecoder().decode(RouteCache.self, from: data) else { return RouteCache() }
        return cache
    }

    func save() {
        var pruned = self
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        pruned.entries = entries.filter { $0.value.date > cutoff }
        if pruned.entries.count > 300 {
            let newest = pruned.entries.sorted { $0.value.date > $1.value.date }.prefix(300)
            pruned.entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(pruned) {
            SharedStore.defaults.set(data, forKey: Self.key)
        }
    }

    private static func cell(_ id: String, _ origin: CLLocationCoordinate2D) -> String {
        "\(id)@\(Int((origin.latitude / 0.003).rounded()))/\(Int((origin.longitude / 0.004).rounded()))"
    }

    func lookup(_ id: String, origin: CLLocationCoordinate2D) -> Entry? {
        entries[Self.cell(id, origin)]
    }

    mutating func store(_ id: String, origin: CLLocationCoordinate2D, km: Double, seconds: Double) {
        entries[Self.cell(id, origin)] = Entry(km: km, seconds: seconds, date: Date())
    }
}
