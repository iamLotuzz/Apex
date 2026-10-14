import Foundation
import CoreLocation
import Observation
import SwiftData
import UIKit

/// Creates a track by driving it: Start while crossing the start/finish line,
/// Stop after the lap.
///
/// The start line is placed where the car was at the moment of the tap,
/// across the direction of travel (40 m wide). The lap ends where the GPS
/// trace crosses that line again, interpolated between fixes, so a late tap
/// on Stop does not change the lap time. Without a crossing the track
/// becomes a sprint (A → B) with its finish line where Stop was tapped.
@MainActor
@Observable
final class TrackRecorder {
    enum Phase {
        case ready, recording, finished
    }

    struct Result {
        var kind: TrackKind
        var startA: CLLocationCoordinate2D
        var startB: CLLocationCoordinate2D
        var finishA: CLLocationCoordinate2D?
        var finishB: CLLocationCoordinate2D?
        var lap: Lap?
        var trace: [CLLocationCoordinate2D]
    }

    private(set) var phase: Phase = .ready
    private(set) var accuracy: Double = -1
    private(set) var speed: Double = 0
    private(set) var distance: Double = 0
    private(set) var startDate: Date?
    private(set) var trace: [CLLocationCoordinate2D] = []
    private(set) var startPoint: CLLocationCoordinate2D?
    private(set) var distanceToStart: Double?
    private(set) var lapClosed = false
    private(set) var result: Result?

    @ObservationIgnored private var fixes: [CLLocation] = []
    @ObservationIgnored private var lastFix: CLLocation?
    @ObservationIgnored private var line: (a: Vec2, b: Vec2, projection: LocalProjection)?
    @ObservationIgnored private var closingCrossing: (time: Date, f: Double, index: Int)?

    private let halfWidth = 20.0
    private let minimumLap = 20.0

    var elapsed: TimeInterval {
        guard let startDate else { return 0 }
        return Date().timeIntervalSince(startDate)
    }

    var gpsReady: Bool { accuracy >= 0 && accuracy <= 30 }

    // MARK: Input

    func process(_ location: CLLocation) {
        accuracy = location.horizontalAccuracy
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50 else { return }
        speed = max(0, location.speed)
        defer { lastFix = location }
        guard phase == .recording, let startDate else { return }

        if let last = fixes.last {
            distance += location.distance(from: last)
        }
        fixes.append(location)
        trace.append(location.coordinate)

        if line == nil {
            line = makeLine(at: startDate)
        }
        if let startPoint {
            distanceToStart = location.distance(from: CLLocation(latitude: startPoint.latitude, longitude: startPoint.longitude))
        }
        if !lapClosed, let crossing = findCrossing(from: fixes.count - 1) {
            closingCrossing = crossing
            lapClosed = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: Buttons

    func start() {
        guard phase == .ready else { return }
        startDate = Date()
        fixes = lastFix.map { [$0] } ?? []
        trace = fixes.map(\.coordinate)
        distance = 0
        lapClosed = false
        closingCrossing = nil
        line = nil
        startPoint = nil
        distanceToStart = nil
        result = nil
        phase = .recording
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    func stop() {
        guard phase == .recording, let startDate else { return }
        let stopDate = Date()
        phase = .finished
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        if line == nil {
            line = makeLine(at: startDate)
        }
        guard let line, let startPoint, fixes.count >= 3 else {
            result = nil
            return
        }

        let crossing = closingCrossing ?? findCrossing(from: 1)
        let kind: TrackKind
        let lapEnd: Date
        let endPoint: CLLocationCoordinate2D
        let endIndex: Int
        var finishA: CLLocationCoordinate2D?
        var finishB: CLLocationCoordinate2D?

        if let crossing {
            kind = .circuit
            lapEnd = crossing.time
            endIndex = crossing.index
            endPoint = Self.lerp(fixes[crossing.index - 1].coordinate, fixes[crossing.index].coordinate, crossing.f)
        } else {
            kind = .sprint
            let last = fixes[fixes.count - 1]
            lapEnd = min(stopDate, last.timestamp)
            endIndex = fixes.count - 1
            endPoint = last.coordinate
            let earlier = fixes[max(0, fixes.count - 4)].coordinate
            let heading = last.course >= 0 && last.speed > 3 ? last.course : Self.bearing(earlier, endPoint)
            let finish = Self.lineEnds(center: endPoint, heading: heading, halfWidth: halfWidth)
            finishA = finish.a
            finishB = finish.b
        }

        let firstMoving = fixes.first { $0.timestamp > startDate }
        var points = [LapPoint(t: 0, lat: startPoint.latitude, lon: startPoint.longitude, speed: max(0, firstMoving?.speed ?? 0))]
        for i in 0..<endIndex where fixes[i].timestamp > startDate {
            let fix = fixes[i]
            points.append(LapPoint(
                t: fix.timestamp.timeIntervalSince(startDate),
                lat: fix.coordinate.latitude,
                lon: fix.coordinate.longitude,
                speed: max(0, fix.speed)
            ))
        }
        let duration = lapEnd.timeIntervalSince(startDate)
        points.append(LapPoint(t: duration, lat: endPoint.latitude, lon: endPoint.longitude, speed: max(0, fixes[endIndex].speed)))

        var lapDistance = 0.0
        for i in 1..<points.count {
            lapDistance += Geo.distance(points[i - 1].coordinate, points[i].coordinate)
        }
        let lap: Lap? = duration > 5 ? Lap(
            number: 1,
            duration: duration,
            distance: lapDistance,
            maxSpeed: points.map(\.speed).max() ?? 0,
            avgSpeed: lapDistance / duration,
            points: points
        ) : nil

        result = Result(
            kind: kind,
            startA: line.projection.coordinate(line.a),
            startB: line.projection.coordinate(line.b),
            finishA: finishA,
            finishB: finishB,
            lap: lap,
            trace: trace
        )
    }

    func reset() {
        phase = .ready
        startDate = nil
        fixes = []
        trace = []
        distance = 0
        line = nil
        startPoint = nil
        distanceToStart = nil
        lapClosed = false
        closingCrossing = nil
        result = nil
    }

    /// Creates the track and stores the driven lap as its first session, so
    /// the next session already shows a delta from lap one.
    func save(name: String, in context: ModelContext) -> Track? {
        guard let result else { return nil }
        let track = Track(
            name: name,
            kind: result.kind,
            startA: Coordinate(result.startA),
            startB: Coordinate(result.startB),
            finishA: result.finishA.map { Coordinate($0) },
            finishB: result.finishB.map { Coordinate($0) }
        )
        context.insert(track)
        if let lap = result.lap {
            let session = TrackSession(
                track: track.snapshot,
                date: startDate ?? Date(),
                endDate: (startDate ?? Date()).addingTimeInterval(lap.duration),
                laps: [lap],
                carID: Persistence.activeCar()?.id
            )
            context.insert(session)
            track.bestLapTime = lap.duration
            track.lapLength = lap.distance
        }
        try? context.save()
        return track
    }

    // MARK: Geometry

    /// The start line: through the position at `date`, across the direction of travel.
    private func makeLine(at date: Date) -> (a: Vec2, b: Vec2, projection: LocalProjection)? {
        guard fixes.count >= 2 else { return nil }
        let before = fixes.last { $0.timestamp <= date } ?? fixes[0]
        guard let after = fixes.first(where: { $0.timestamp > date }) else { return nil }
        let span = after.timestamp.timeIntervalSince(before.timestamp)
        let f = span > 0 ? min(1, max(0, date.timeIntervalSince(before.timestamp) / span)) : 0
        let center = Self.lerp(before.coordinate, after.coordinate, f)
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)

        var heading: Double?
        if after.course >= 0 && after.speed > 3 {
            heading = after.course
        } else if let far = fixes.first(where: { $0.timestamp > date && $0.distance(from: centerLocation) > 15 }) {
            heading = Self.bearing(center, far.coordinate)
        }
        guard let heading else { return nil }

        let projection = LocalProjection(origin: center)
        let radians = heading * .pi / 180
        let normal = Vec2(x: cos(radians), y: -sin(radians))
        startPoint = center
        return (normal * halfWidth, normal * -halfWidth, projection)
    }

    private func findCrossing(from index: Int) -> (time: Date, f: Double, index: Int)? {
        guard let line, let startDate else { return nil }
        let first = max(1, index)
        guard first < fixes.count else { return nil }
        for i in first..<fixes.count {
            let a = fixes[i - 1]
            let b = fixes[i]
            guard b.timestamp.timeIntervalSince(startDate) >= minimumLap else { continue }
            let pa = line.projection.point(a.coordinate)
            let pb = line.projection.point(b.coordinate)
            if let f = LapMath.crossing(pa, pb, line.a, line.b) {
                let tf = LapMath.timeFraction(distanceFraction: f, v1: max(0, a.speed), v2: max(0, b.speed))
                let time = a.timestamp.addingTimeInterval(b.timestamp.timeIntervalSince(a.timestamp) * tf)
                return (time, f, i)
            }
        }
        return nil
    }

    private static func lineEnds(center: CLLocationCoordinate2D, heading: Double, halfWidth: Double) -> (a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) {
        let projection = LocalProjection(origin: center)
        let radians = heading * .pi / 180
        let normal = Vec2(x: cos(radians), y: -sin(radians))
        return (projection.coordinate(normal * halfWidth), projection.coordinate(normal * -halfWidth))
    }

    private static func lerp(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ f: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * f,
            longitude: a.longitude + (b.longitude - a.longitude) * f
        )
    }

    /// Compass bearing from `a` to `b` in degrees.
    private static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p = LocalProjection(origin: a).point(b)
        let degrees = atan2(p.x, p.y) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
