import Foundation
import CoreLocation
import Observation

/// The speed limit to show.
struct SpeedLimit: Equatable {
    enum Kind: Equatable {
        /// A number in km/h.
        case limit(Int)
        /// No limit (German motorway); 130 is the recommended speed.
        case none
        /// Electronic signs (Verkehrsbeeinflussungsanlage): no data exists.
        case variable
    }

    var kind: Kind
    /// Not signposted in the map data, derived from the StVO rules for the
    /// type of road (urban 50, rural 100, …). Shown paler.
    var estimated: Bool

    /// km/h for the speeding check, nil when there is no number.
    var kmh: Int? {
        if case .limit(let value) = kind { return value }
        return nil
    }
}

/// Current speed limit from OpenStreetMap (Overpass API). Apple does not
/// share its speed limits with other apps.
///
/// - At navigation start the whole route corridor is loaded (in chunks,
///   nearest first), so the limit is there even without signal and changes
///   right at the sign. Off the route, roads within 80 m are loaded as
///   before.
/// - Roads without a `maxspeed` tag get the legal limit for their type:
///   inside towns (mapped residential/commercial areas or `zone:traffic`)
///   50, outside 100, living streets walking pace, motorways no limit.
/// - Conditional limits are applied: times ("30 @ (22:00-06:00)",
///   "Mo-Fr 07:00-18:00") and wet roads ("80 @ wet", from the weather).
/// - A spatial grid keeps the lookup per fix cheap on long routes.
@MainActor
@Observable
final class SpeedLimitService {
    static let shared = SpeedLimitService()

    private(set) var current: SpeedLimit?
    /// OSM road class of the matched road ("motorway", "primary", …).
    private(set) var roadClass: String?

    /// km/h; 0 means no limit; nil means unknown or variable.
    var limit: Int? {
        guard let current else { return nil }
        switch current.kind {
        case .limit(let value): return value
        case .none: return 0
        case .variable: return nil
        }
    }

    /// Set from the weather while navigating, for "@ wet" limits.
    var roadIsWet = false

    private struct Way {
        let points: [CLLocationCoordinate2D]
        let forward: Rule
        let backward: Rule
        let highway: String
    }

    /// The limit of one direction of a road, with its conditions.
    private struct Rule {
        var base: SpeedLimit?
        var conditional: [(SpeedLimit.Kind, String)] = []
    }

    private struct SegmentRef: Hashable {
        let way: Int
        let segment: Int
    }

    @ObservationIgnored private var ways: [Way] = []
    @ObservationIgnored private var wayIDs: Set<Int> = []
    @ObservationIgnored private var grid: [Int64: [SegmentRef]] = [:]
    @ObservationIgnored private var urbanAreas: [[CLLocationCoordinate2D]] = []
    @ObservationIgnored private var pendingWays: [RawWay] = []
    @ObservationIgnored private var lastQuery: CLLocation?
    @ObservationIgnored private var lastQueryDate = Date.distantPast
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var candidate: SpeedLimit?
    @ObservationIgnored private var candidateCount = 0

    func reset() {
        prefetchTask?.cancel()
        prefetchTask = nil
        ways = []
        wayIDs = []
        grid = [:]
        urbanAreas = []
        current = nil
        roadClass = nil
        lastQuery = nil
        candidate = nil
        candidateCount = 0
    }

    // MARK: Route prefetch

    /// Loads the limits along a whole route: points every ~150 m, sent in
    /// chunks of ~9 km, nearest chunk first.
    func prefetch(route coordinates: [CLLocationCoordinate2D]) {
        prefetchTask?.cancel()
        guard coordinates.count >= 2 else { return }
        var samples: [CLLocationCoordinate2D] = [coordinates[0]]
        for c in coordinates.dropFirst() {
            if let last = samples.last, Geo.distance(last, c) >= 150 { samples.append(c) }
        }
        if let last = coordinates.last { samples.append(last) }
        var chunks: [[CLLocationCoordinate2D]] = []
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + 60)
            // Overlap by one point so no gap stays between chunks.
            chunks.append(Array(samples[max(0, i - 1)..<end]))
            i = end
        }
        prefetchTask = Task { [weak self] in
            for chunk in chunks {
                if Task.isCancelled { return }
                let line = chunk.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
                if let result = try? await Self.fetch(filter: "around:30,\(line)") {
                    self?.add(result)
                }
                // Be polite to the public Overpass server.
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    // MARK: Per fix

    func update(location: CLLocation, heading: Double) {
        evaluate(location.coordinate, heading: heading)
        // Fallback around the car, e.g. after leaving the route.
        let moved = lastQuery.map { location.distance(from: $0) } ?? .infinity
        guard !loading, current == nil || prefetchTask == nil,
              moved > 150 || Date().timeIntervalSince(lastQueryDate) > 30 else { return }
        loading = true
        lastQuery = location
        lastQueryDate = Date()
        let c = location.coordinate
        Task {
            if let fetched = try? await Self.fetch(filter: "around:80,\(c.latitude),\(c.longitude)") {
                add(fetched)
                evaluate(c, heading: heading)
            }
            loading = false
        }
    }

    private func evaluate(_ c: CLLocationCoordinate2D, heading: Double) {
        let projection = LocalProjection(origin: c)
        var best: (score: Double, distance: Double, way: Int, forward: Bool)?
        let (row, col) = Self.cell(c)
        for dr in -1...1 {
            for dc in -1...1 {
                for ref in grid[Self.key(row + dr, col + dc)] ?? [] {
                    let way = ways[ref.way]
                    let a = projection.point(way.points[ref.segment])
                    let b = projection.point(way.points[ref.segment + 1])
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
                    if score < (best?.score ?? .infinity) {
                        best = (score, d, ref.way, diff <= 90)
                    }
                }
            }
        }
        guard let best, best.score < 35 else {
            if best == nil || (best?.distance ?? 0) > 60 { publish(nil, roadClass: nil) }
            return
        }
        let way = ways[best.way]
        let rule = best.forward ? way.forward : way.backward
        publish(resolve(rule), roadClass: way.highway)
    }

    /// A new value must be seen on two fixes in a row, so the sign does not
    /// flicker at junctions where a side road is momentarily closer.
    private func publish(_ value: SpeedLimit?, roadClass: String?) {
        if value == current {
            candidateCount = 0
            self.roadClass = roadClass
            return
        }
        if value == candidate {
            candidateCount += 1
        } else {
            candidate = value
            candidateCount = 1
        }
        if candidateCount >= 2 || current == nil {
            current = value
            self.roadClass = roadClass
            candidateCount = 0
        }
    }

    private func resolve(_ rule: Rule) -> SpeedLimit? {
        let now = Date()
        for (value, condition) in rule.conditional where ConditionParser.applies(condition, at: now, wet: roadIsWet) {
            return SpeedLimit(kind: value, estimated: false)
        }
        return rule.base
    }

    // MARK: Data

    private func add(_ result: FetchResult) {
        urbanAreas.append(contentsOf: result.urban)
        pendingWays.append(contentsOf: result.ways.filter { !wayIDs.contains($0.id) })
        // Ways are built after the areas, so the urban test sees both.
        let raw = pendingWays
        pendingWays = []
        for way in raw where !wayIDs.contains(way.id) {
            wayIDs.insert(way.id)
            let built = build(way)
            let index = ways.count
            ways.append(built)
            for s in 0..<(built.points.count - 1) {
                let (row, col) = Self.cell(built.points[s])
                let (row2, col2) = Self.cell(built.points[s + 1])
                for r in min(row, row2)...max(row, row2) {
                    for c in min(col, col2)...max(col, col2) {
                        grid[Self.key(r, c), default: []].append(SegmentRef(way: index, segment: s))
                    }
                }
            }
        }
    }

    private func build(_ raw: RawWay) -> Way {
        let tags = raw.tags
        let highway = tags["highway"] ?? "road"
        let general = Self.parse(tags["maxspeed"])
        let forwardTag = Self.parse(tags["maxspeed:forward"]) ?? general
        let backwardTag = Self.parse(tags["maxspeed:backward"]) ?? general
        let fallback = forwardTag == nil || backwardTag == nil ? legalLimit(raw, highway: highway) : nil

        func conditions(_ key: String) -> [(SpeedLimit.Kind, String)] {
            guard let value = tags[key] ?? tags["maxspeed:conditional"] else { return [] }
            return ConditionParser.rules(value)
        }
        return Way(
            points: raw.points,
            forward: Rule(base: forwardTag ?? fallback, conditional: conditions("maxspeed:forward:conditional")),
            backward: Rule(base: backwardTag ?? fallback, conditional: conditions("maxspeed:backward:conditional")),
            highway: highway
        )
    }

    /// StVO § 3 limits for a road without a signposted limit.
    private func legalLimit(_ way: RawWay, highway: String) -> SpeedLimit? {
        let tags = way.tags
        let type = (tags["zone:traffic"] ?? tags["source:maxspeed"] ?? tags["maxspeed:type"] ?? "").lowercased()
        switch highway {
        case "motorway":
            return SpeedLimit(kind: .none, estimated: true)
        case "living_street":
            return SpeedLimit(kind: .limit(7), estimated: true)
        case "track", "path", "footway", "cycleway", "pedestrian", "steps", "construction":
            return nil
        default:
            break
        }
        if type.hasSuffix("urban") { return SpeedLimit(kind: .limit(50), estimated: true) }
        if type.hasSuffix("rural") { return SpeedLimit(kind: .limit(100), estimated: true) }
        if type.hasSuffix("motorway") { return SpeedLimit(kind: .none, estimated: true) }
        // Inside a mapped town area: built-up, 50. Residential and service
        // roads are almost always inside one.
        let middle = way.points[way.points.count / 2]
        let urban = ["residential", "service"].contains(highway) || urbanAreas.contains { Self.contains($0, middle) }
        return SpeedLimit(kind: .limit(urban ? 50 : 100), estimated: true)
    }

    // MARK: Grid

    /// ~110 m × ~75 m cells (Germany).
    private static func cell(_ c: CLLocationCoordinate2D) -> (Int, Int) {
        (Int((c.latitude / 0.001).rounded(.down)), Int((c.longitude / 0.0011).rounded(.down)))
    }

    private static func key(_ row: Int, _ col: Int) -> Int64 {
        Int64(row) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: col)))
    }

    /// Point in polygon (ray casting).
    private static func contains(_ polygon: [CLLocationCoordinate2D], _ p: CLLocationCoordinate2D) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                let x = (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if p.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: Overpass

    private struct RawWay {
        let id: Int
        let tags: [String: String]
        let points: [CLLocationCoordinate2D]
    }

    private struct FetchResult {
        var ways: [RawWay] = []
        var urban: [[CLLocationCoordinate2D]] = []
    }

    private static let roadTypes = "motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street|service|road"

    private static func fetch(filter: String) async throws -> FetchResult {
        let query = """
        [out:json][timeout:20];
        (way(\(filter))[highway~"^(\(roadTypes))$"];
         way(\(filter))[landuse~"^(residential|commercial|retail|industrial)$"];);
        out tags geom;
        """
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(Response.self, from: data)
        var result = FetchResult()
        for element in response.elements {
            guard let geometry = element.geometry, geometry.count >= 2, let tags = element.tags else { continue }
            let points = geometry.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            if tags["landuse"] != nil {
                result.urban.append(points)
            } else {
                result.ways.append(RawWay(id: element.id, tags: tags, points: points))
            }
        }
        return result
    }

    /// "50", "30 mph", "DE:urban", "none", "signals" … → limit.
    nonisolated static func parse(_ value: String?) -> SpeedLimit? {
        guard let kind = parseKind(value) else { return nil }
        return SpeedLimit(kind: kind, estimated: false)
    }

    nonisolated static func parseKind(_ value: String?) -> SpeedLimit.Kind? {
        guard let raw = value?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw == "none" || raw.hasSuffix(":motorway") { return SpeedLimit.Kind.none }
        if raw == "signals" || raw == "variable" { return .variable }
        if raw.hasSuffix(":urban") { return .limit(50) }
        if raw.hasSuffix(":rural") { return .limit(100) }
        if raw.contains("living_street") || raw == "walk" { return .limit(7) }
        if raw.contains("zone30") || raw.contains("zone:30") { return .limit(30) }
        if raw.contains("zone20") || raw.contains("zone:20") { return .limit(20) }
        let digits = raw.prefix { $0.isNumber }
        guard let number = Int(digits), number > 0 else { return nil }
        return .limit(raw.contains("mph") ? Int((Double(number) * 1.609).rounded()) : number)
    }

    private struct Response: Decodable {
        struct Point: Decodable {
            let lat: Double
            let lon: Double
        }

        struct Element: Decodable {
            let id: Int
            let tags: [String: String]?
            let geometry: [Point]?
        }

        let elements: [Element]
    }
}

/// OSM conditional restrictions: "30 @ (22:00-06:00); 80 @ wet".
enum ConditionParser {
    static func rules(_ value: String) -> [(SpeedLimit.Kind, String)] {
        value.split(separator: ";").compactMap { part in
            let pieces = part.split(separator: "@", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2, let kind = SpeedLimitService.parseKind(pieces[0]) else { return nil }
            let condition = pieces[1].trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            return (kind, condition)
        }
    }

    /// Supports "wet", time ranges ("22:00-06:00", several with ","), and
    /// weekday ranges in front ("Mo-Fr 07:00-19:00"). Anything else
    /// (dates, "snow", vehicle types) does not apply.
    static func applies(_ condition: String, at date: Date, wet: Bool) -> Bool {
        let text = condition.lowercased()
        if text == "wet" { return wet }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        // Gregorian weekday: 1 = Sunday … 7 = Saturday → 0 = Monday.
        let weekday = ((parts.weekday ?? 2) + 5) % 7
        let days = ["mo", "tu", "we", "th", "fr", "sa", "su"]

        var dayOK = true
        var timeText = text
        if let first = text.split(separator: " ").first, days.contains(where: { first.hasPrefix($0) }) {
            dayOK = false
            for range in first.split(separator: ",") {
                let ends = range.split(separator: "-").map(String.init)
                guard let a = days.firstIndex(of: String(ends[0].prefix(2))) else { continue }
                let b = ends.count > 1 ? (days.firstIndex(of: String(ends[1].prefix(2))) ?? a) : a
                if a <= b ? (weekday >= a && weekday <= b) : (weekday >= a || weekday <= b) { dayOK = true }
            }
            timeText = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
        }
        guard dayOK else { return false }
        if timeText.isEmpty { return true }
        var matched = false
        for range in timeText.split(separator: ",") {
            let ends = range.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard ends.count == 2, let from = minutes(ends[0]), let to = minutes(ends[1]) else { return false }
            if from <= to ? (minute >= from && minute < to) : (minute >= from || minute < to) { matched = true }
        }
        return matched
    }

    private static func minutes(_ text: String) -> Int? {
        let p = text.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }
}
