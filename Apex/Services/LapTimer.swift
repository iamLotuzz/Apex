import Foundation
import CoreLocation
import Observation
import UIKit

struct Vec2 {
    var x: Double
    var y: Double

    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    static func * (a: Vec2, s: Double) -> Vec2 { Vec2(x: a.x * s, y: a.y * s) }

    func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    var length: Double { (x * x + y * y).squareRoot() }
}

/// Flat metre coordinates around a track. Accurate enough for a few kilometres.
struct LocalProjection {
    let origin: CLLocationCoordinate2D
    private let metersPerDegLat = 111_320.0
    private let metersPerDegLon: Double

    init(origin: CLLocationCoordinate2D) {
        self.origin = origin
        metersPerDegLon = 111_320.0 * cos(origin.latitude * .pi / 180)
    }

    func point(_ c: CLLocationCoordinate2D) -> Vec2 {
        Vec2(x: (c.longitude - origin.longitude) * metersPerDegLon,
             y: (c.latitude - origin.latitude) * metersPerDegLat)
    }

    func coordinate(_ p: Vec2) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + p.y / metersPerDegLat,
                               longitude: origin.longitude + p.x / metersPerDegLon)
    }
}

enum LapMath {
    /// Fraction along p1→p2 where it crosses the line a→b, or nil.
    static func crossing(_ p1: Vec2, _ p2: Vec2, _ a: Vec2, _ b: Vec2) -> Double? {
        let r = p2 - p1
        let s = b - a
        let denom = r.cross(s)
        guard abs(denom) > 1e-9 else { return nil }
        let qp = a - p1
        let t = qp.cross(s) / denom
        let u = qp.cross(r) / denom
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return t
    }

    /// Time fraction (0...1) at which the car covered `f` of the distance
    /// between two fixes, assuming constant acceleration from `v1` to `v2`.
    /// Linear interpolation is only exact at constant speed; near a braking
    /// or launch zone this removes up to ~0.1 s of error.
    static func timeFraction(distanceFraction f: Double, v1: Double, v2: Double) -> Double {
        guard v1 >= 0, v2 >= 0, v1 + v2 > 0.1 else { return f }
        // s(τ) = v1·τ + (v2 − v1)·τ²/2 with τ in units of the fix interval.
        let a = (v2 - v1) / 2
        let b = v1
        let c = -f * (v1 + v2) / 2
        if abs(a) < 1e-6 {
            return b > 0 ? min(1, max(0, -c / b)) : f
        }
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return f }
        let tau = (-b + discriminant.squareRoot()) / (2 * a)
        return min(1, max(0, tau))
    }
}

enum LapReference: String, CaseIterable, Identifiable {
    case previous, best

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previous: return "Vorherige Runde"
        case .best: return "Beste Runde"
        }
    }
}

/// Live lap timing with a continuous delta against a reference lap.
///
/// Laps start and end where the GPS track crosses the start/finish line; the
/// crossing time is interpolated between two fixes. The delta compares the
/// current lap time with the reference lap's time at the nearest point on its
/// trace.
@MainActor
@Observable
final class LapTimer {
    enum Phase {
        case waitingForStart
        case running
    }

    enum Event: Equatable {
        case started
        case lapCompleted(number: Int, isBest: Bool)
        case finished
    }

    let track: TrackSnapshot
    var reference: LapReference

    private(set) var phase: Phase = .waitingForStart
    private(set) var laps: [Lap] = []
    private(set) var lapStart: Date?
    private(set) var delta: Double?
    private(set) var speed: Double = 0
    private(set) var accuracy: Double = -1
    private(set) var lastEvent: Event?
    private(set) var eventCount = 0
    private(set) var sessionStart = Date()

    private let projection: LocalProjection
    private let startA: Vec2
    private let startB: Vec2
    private let finishA: Vec2
    private let finishB: Vec2
    @ObservationIgnored private var previous: (xy: Vec2, time: Date, point: LapPoint)?
    @ObservationIgnored private var current: [LapPoint] = []
    @ObservationIgnored private var refXY: [Vec2] = []
    @ObservationIgnored private var refT: [Double] = []
    @ObservationIgnored private var refIndex = 0
    @ObservationIgnored private var refKey: String?
    @ObservationIgnored private var filterState: (xy: Vec2, time: Date, velocity: Vec2)?

    var minimumLapTime: Double = 15

    /// Best lap from earlier sessions (or the lap recorded when the track was
    /// created). Gives the first lap of a session a delta too.
    let storedReference: Lap?

    init(track: TrackSnapshot, reference: LapReference, storedReference: Lap? = nil) {
        self.track = track
        self.reference = reference
        self.storedReference = storedReference
        let center = CLLocationCoordinate2D(
            latitude: (track.startA.lat + track.startB.lat) / 2,
            longitude: (track.startA.lon + track.startB.lon) / 2
        )
        let projection = LocalProjection(origin: center)
        self.projection = projection
        startA = projection.point(track.startA.clCoordinate)
        startB = projection.point(track.startB.clCoordinate)
        finishA = projection.point((track.finishA ?? track.startA).clCoordinate)
        finishB = projection.point((track.finishB ?? track.startB).clCoordinate)
    }

    var bestLap: Lap? { laps.min { $0.duration < $1.duration } }
    var lastLap: Lap? { laps.last }

    var referenceLap: Lap? {
        switch reference {
        case .previous:
            return laps.last ?? storedReference
        case .best:
            return [bestLap, storedReference].compactMap { $0 }.min { $0.duration < $1.duration }
        }
    }

    /// True while the delta compares against a lap from an earlier session.
    var referenceIsStored: Bool {
        guard let ref = referenceLap, let stored = storedReference else { return false }
        return ref == stored && !laps.contains(ref)
    }

    /// How far through the lap the car is (0…1), measured on the reference trace.
    var lapProgress: Double? {
        guard phase == .running, refXY.count >= 2 else { return nil }
        return min(1, Double(refIndex) / Double(refXY.count - 1))
    }

    var currentLapTime: Double {
        guard phase == .running, let lapStart else { return 0 }
        return Date().timeIntervalSince(lapStart)
    }

    /// Reference lap time plus the current delta.
    var predictedLapTime: Double? {
        guard let delta, let ref = referenceLap else { return nil }
        return ref.duration + delta
    }

    var currentLapNumber: Int { laps.count + 1 }

    // MARK: Input

    func process(_ location: CLLocation) {
        accuracy = location.horizontalAccuracy
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50 else { return }
        let time = location.timestamp
        let xy = filtered(projection.point(location.coordinate), location: location, time: time)
        let coordinate = projection.coordinate(xy)
        speed = max(0, location.speed)
        let point = LapPoint(t: 0, lat: coordinate.latitude, lon: coordinate.longitude, speed: speed)

        if let prev = previous, time > prev.time {
            switch track.kind {
            case .circuit:
                if let f = LapMath.crossing(prev.xy, xy, startA, startB) {
                    let crossing = interpolate(prev.point, point, prev.time, time, f)
                    if phase == .running, let lapStart, crossing.time.timeIntervalSince(lapStart) >= minimumLapTime {
                        completeLap(endTime: crossing.time, endPoint: crossing.point)
                        startLap(at: crossing.time, point: crossing.point)
                    } else if phase == .waitingForStart {
                        startLap(at: crossing.time, point: crossing.point)
                        emit(.started)
                    }
                }
            case .sprint:
                if phase == .waitingForStart, let f = LapMath.crossing(prev.xy, xy, startA, startB) {
                    let crossing = interpolate(prev.point, point, prev.time, time, f)
                    startLap(at: crossing.time, point: crossing.point)
                    emit(.started)
                } else if phase == .running, let lapStart, let f = LapMath.crossing(prev.xy, xy, finishA, finishB) {
                    let crossing = interpolate(prev.point, point, prev.time, time, f)
                    if crossing.time.timeIntervalSince(lapStart) >= minimumLapTime {
                        completeLap(endTime: crossing.time, endPoint: crossing.point)
                        phase = .waitingForStart
                        self.lapStart = nil
                        delta = nil
                    }
                }
            }
        }

        if phase == .running, let lapStart {
            var p = point
            p.t = time.timeIntervalSince(lapStart)
            if p.t > (current.last?.t ?? -1) {
                current.append(p)
                updateDelta(xy: xy, elapsed: p.t)
            }
        }
        previous = (xy, time, point)
    }

    // MARK: Laps

    /// `f` is the distance fraction where the line was crossed. The time comes
    /// from a constant-acceleration model using the Doppler speeds of both fixes.
    private func interpolate(_ a: LapPoint, _ b: LapPoint, _ ta: Date, _ tb: Date, _ f: Double) -> (time: Date, point: LapPoint) {
        let tf = LapMath.timeFraction(distanceFraction: f, v1: a.speed, v2: b.speed)
        let time = ta.addingTimeInterval(tb.timeIntervalSince(ta) * tf)
        let point = LapPoint(
            t: 0,
            lat: a.lat + (b.lat - a.lat) * f,
            lon: a.lon + (b.lon - a.lon) * f,
            speed: a.speed + (b.speed - a.speed) * tf
        )
        return (time, point)
    }

    // MARK: Position filter

    /// Velocity in metres per second (x = east, y = north) from the GPS
    /// Doppler speed and course, or nil when they are not reliable.
    private func velocityVector(_ location: CLLocation) -> Vec2? {
        guard location.speed > 2, location.course >= 0 else { return nil }
        if location.courseAccuracy >= 0 && location.courseAccuracy > 25 { return nil }
        let radians = location.course * .pi / 180
        return Vec2(x: location.speed * sin(radians), y: location.speed * cos(radians))
    }

    /// Blends each GPS position with a prediction from the previous position
    /// and the Doppler velocity. Doppler speed is accurate to ~0.1 m/s while a
    /// single position jumps by 2–5 m, so this removes most of the random
    /// jitter that would otherwise shift line crossings by a few hundredths.
    private func filtered(_ raw: Vec2, location: CLLocation, time: Date) -> Vec2 {
        guard let velocity = velocityVector(location) else {
            filterState = nil
            return raw
        }
        guard let state = filterState else {
            filterState = (raw, time, velocity)
            return raw
        }
        let dt = time.timeIntervalSince(state.time)
        guard dt > 0, dt <= 2.5 else {
            filterState = (raw, time, velocity)
            return raw
        }
        let predicted = state.xy + (state.velocity + velocity) * (0.5 * dt)
        let speedSigma = location.speedAccuracy >= 0 ? location.speedAccuracy : 0.5
        let predictionSigma = 0.4 + speedSigma * dt
        let measurementSigma = max(1.5, location.horizontalAccuracy * 0.6)
        let p2 = predictionSigma * predictionSigma
        let gain = min(1, max(0.2, p2 / (p2 + measurementSigma * measurementSigma)))
        let result = predicted + (raw - predicted) * gain
        filterState = (result, time, velocity)
        return result
    }

    private func startLap(at time: Date, point: LapPoint) {
        phase = .running
        lapStart = time
        var first = point
        first.t = 0
        current = [first]
        refIndex = 0
        delta = referenceLap == nil ? nil : 0
        prepareReference()
    }

    private func completeLap(endTime: Date, endPoint: LapPoint) {
        guard let lapStart else { return }
        var last = endPoint
        last.t = endTime.timeIntervalSince(lapStart)
        current.append(last)
        let duration = last.t

        var distance = 0.0
        for i in 1..<current.count {
            distance += Geo.distance(current[i - 1].coordinate, current[i].coordinate)
        }
        let maxSpeed = current.map(\.speed).max() ?? 0
        let lap = Lap(
            number: laps.count + 1,
            duration: duration,
            distance: distance,
            maxSpeed: maxSpeed,
            avgSpeed: duration > 0 ? distance / duration : 0,
            points: current
        )
        let previousBest = bestLap?.duration ?? .infinity
        laps.append(lap)
        emit(.lapCompleted(number: lap.number, isBest: duration < previousBest))
    }

    private func emit(_ event: Event) {
        lastEvent = event
        eventCount += 1
        let generator = UINotificationFeedbackGenerator()
        switch event {
        case .lapCompleted(_, let isBest):
            generator.notificationOccurred(isBest ? .success : .warning)
        case .started, .finished:
            generator.notificationOccurred(.success)
        }
    }

    // MARK: Delta

    private func prepareReference() {
        guard let ref = referenceLap else {
            refXY = []
            refT = []
            refKey = nil
            return
        }
        let key = "\(ref.number)-\(ref.duration)"
        guard key != refKey else { return }
        refKey = key
        refXY = ref.points.map { projection.point($0.coordinate) }
        refT = ref.points.map(\.t)
    }

    func referenceChanged() {
        refKey = nil
        prepareReference()
    }

    private func updateDelta(xy: Vec2, elapsed: Double) {
        guard refXY.count >= 2 else { return }
        if let match = nearest(xy, from: max(0, refIndex - 3), to: min(refXY.count - 2, refIndex + 40)), match.distance < 40 {
            refIndex = match.index
            delta = elapsed - match.time
        } else if let match = nearest(xy, from: 0, to: refXY.count - 2), match.distance < 40 {
            refIndex = match.index
            delta = elapsed - match.time
        }
    }

    private func nearest(_ p: Vec2, from lo: Int, to hi: Int) -> (index: Int, time: Double, distance: Double)? {
        guard lo <= hi else { return nil }
        var best: (index: Int, time: Double, distance: Double)?
        for i in lo...hi {
            let a = refXY[i]
            let b = refXY[i + 1]
            let ab = b - a
            let len2 = ab.dot(ab)
            let u = len2 > 0 ? min(1, max(0, (p - a).dot(ab) / len2)) : 0
            let projected = a + ab * u
            let d = (p - projected).length
            if d < (best?.distance ?? .infinity) {
                let t = refT[i] + (refT[i + 1] - refT[i]) * u
                best = (i, t, d)
            }
        }
        return best
    }

    // MARK: Results

    var sessionDuration: Double { Date().timeIntervalSince(sessionStart) }
}
