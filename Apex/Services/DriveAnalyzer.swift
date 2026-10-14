import Foundation
import CoreLocation

struct SpeedBucket: Identifiable {
    var label: String
    var lower: Double   // km/h
    var seconds: Double

    var id: String { label }
}

struct SeriesPoint: Identifiable {
    var id: Int
    var minute: Double
    var kmh: Double
    var altitude: Double
}

struct DriveStats {
    var distance: Double = 0
    var duration: Double = 0
    var movingTime: Double = 0
    var stoppedTime: Double = 0
    var stopCount = 0
    var maxSpeed: Double = 0
    var maxSpeedIndex: Int?
    var avgSpeed: Double = 0
    var avgMovingSpeed: Double = 0
    var elevationGain: Double = 0
    var elevationLoss: Double = 0
    var minAltitude: Double?
    var maxAltitude: Double?
    var maxAcceleration: Double = 0   // m/s²
    var maxDeceleration: Double = 0   // m/s², positive value
    var zeroTo50: Double?
    var zeroTo100: Double?
    var eightyTo120: Double?
    var timeAbove100: Double = 0
    var timeAbove130: Double = 0
    var curvature: Double = 0         // degrees of heading change per km
    var buckets: [SpeedBucket] = []
    var series: [SeriesPoint] = []

    var curvatureLabel: String {
        switch curvature {
        case ..<60: return "Gerade"
        case ..<180: return "Leicht kurvig"
        case ..<400: return "Kurvig"
        default: return "Sehr kurvig"
        }
    }
}

enum Geo {
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Returns at most `maxCount` evenly spaced elements, keeping the last one.
    static func downsample<T>(_ items: [T], maxCount: Int) -> [T] {
        guard items.count > maxCount, maxCount > 1 else { return items }
        let step = Double(items.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { items[Int((Double($0) * step).rounded())] }
    }
}

enum DriveAnalyzer {
    static let bucketEdges: [Double] = [0, 30, 50, 80, 100, 130, 160]

    static func analyze(_ points: [DrivePoint], launches: [Double] = []) -> DriveStats {
        var s = DriveStats()
        guard points.count >= 2, let first = points.first, let last = points.last else { return s }
        s.duration = max(0, last.t - first.t)

        let speeds = smoothedSpeeds(points)
        var bucketSeconds = [Double](repeating: 0, count: bucketEdges.count)
        var stoppedFor: Double = 0
        var countedStop = false
        var turning: Double = 0

        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            let dt = b.t - a.t
            guard dt > 0, dt < 60 else { continue }

            let d = Geo.distance(a.coordinate, b.coordinate)
            if d / dt < 95 { s.distance += d }

            let v = speeds[i]
            if v > 1.4 {
                s.movingTime += dt
                stoppedFor = 0
                countedStop = false
            } else {
                s.stoppedTime += dt
                stoppedFor += dt
                if stoppedFor >= 10 && !countedStop && s.movingTime > 0 {
                    s.stopCount += 1
                    countedStop = true
                }
            }

            let kmh = v * 3.6
            if kmh > 100 { s.timeAbove100 += dt }
            if kmh > 130 { s.timeAbove130 += dt }
            if v > 1.4 {
                let index = (bucketEdges.lastIndex { kmh >= $0 }) ?? 0
                bucketSeconds[index] += dt
            }

            if dt <= 3 {
                let acc = (speeds[i] - speeds[i - 1]) / dt
                if abs(acc) < 12 {
                    s.maxAcceleration = max(s.maxAcceleration, acc)
                    s.maxDeceleration = max(s.maxDeceleration, -acc)
                }
            }

            if a.course >= 0, b.course >= 0, a.speed > 4, b.speed > 4 {
                var change = abs(b.course - a.course)
                if change > 180 { change = 360 - change }
                if change < 90 { turning += change }
            }
        }

        for (i, p) in points.enumerated() where p.accuracy <= 35 && p.speed > s.maxSpeed {
            s.maxSpeed = p.speed
            s.maxSpeedIndex = i
        }
        if s.maxSpeedIndex == nil, let maxSmoothed = speeds.max() {
            s.maxSpeed = maxSmoothed
            s.maxSpeedIndex = speeds.firstIndex(of: maxSmoothed)
        }

        s.avgSpeed = s.duration > 0 ? s.distance / s.duration : 0
        s.avgMovingSpeed = s.movingTime > 0 ? s.distance / s.movingTime : 0
        s.curvature = s.distance > 200 ? turning / (s.distance / 1000) : 0

        s.buckets = bucketEdges.enumerated().map { index, lower in
            let label: String
            if index + 1 < bucketEdges.count {
                label = "\(Int(lower))–\(Int(bucketEdges[index + 1]))"
            } else {
                label = "\(Int(lower))+"
            }
            return SpeedBucket(label: label, lower: lower, seconds: bucketSeconds[index])
        }

        applyElevation(points, to: &s)
        // Sprint times use the raw Doppler speeds: smoothing would blur the launch.
        let raw = rawSpeeds(points)
        s.zeroTo50 = sprint(points, speeds: raw, from: 0, to: 50, launches: launches)
        s.zeroTo100 = sprint(points, speeds: raw, from: 0, to: 100, launches: launches)
        s.eightyTo120 = sprint(points, speeds: raw, from: 80, to: 120, launches: launches)
        s.series = series(points, speeds: speeds, start: first.t)
        return s
    }

    /// GPS Doppler speed per point. Falls back to distance/time when the GPS
    /// reports no speed.
    static func rawSpeeds(_ points: [DrivePoint]) -> [Double] {
        var raw = [Double](repeating: 0, count: points.count)
        for i in points.indices {
            if points[i].speed >= 0 {
                raw[i] = points[i].speed
            } else if i > 0 {
                let dt = points[i].t - points[i - 1].t
                raw[i] = dt > 0 ? Geo.distance(points[i - 1].coordinate, points[i].coordinate) / dt : 0
            }
        }
        return raw
    }

    /// Speed per point with a 3-point moving average.
    static func smoothedSpeeds(_ points: [DrivePoint]) -> [Double] {
        let raw = rawSpeeds(points)
        guard raw.count >= 3 else { return raw }
        var smooth = raw
        for i in 1..<(raw.count - 1) {
            smooth[i] = (raw[i - 1] + raw[i] + raw[i + 1]) / 3
        }
        return smooth
    }

    private static func applyElevation(_ points: [DrivePoint], to s: inout DriveStats) {
        let alts = points.map(\.alt)
        guard alts.count >= 5 else { return }
        var smooth = [Double]()
        smooth.reserveCapacity(alts.count)
        for i in alts.indices {
            let lo = max(0, i - 2)
            let hi = min(alts.count - 1, i + 2)
            let window = alts[lo...hi]
            smooth.append(window.reduce(0, +) / Double(window.count))
        }
        s.minAltitude = smooth.min()
        s.maxAltitude = smooth.max()
        var anchor = smooth[0]
        for value in smooth {
            let diff = value - anchor
            if diff >= 3 {
                s.elevationGain += diff
                anchor = value
            } else if diff <= -3 {
                s.elevationLoss -= diff
                anchor = value
            }
        }
    }

    /// Best time from `from` km/h to `to` km/h.
    ///
    /// The 1 Hz GPS only says the car stood still at one fix and moved at the
    /// next, so a standing start is refined: first with the launch moments the
    /// accelerometer recorded (50 Hz), otherwise by extrapolating the measured
    /// acceleration back to zero speed. Target speeds are found on a quadratic
    /// fit through three fixes instead of a straight line, which matters
    /// because speed rises in a curve under hard acceleration.
    static func sprint(_ points: [DrivePoint], speeds: [Double], from: Double, to: Double, launches: [Double] = []) -> Double? {
        guard points.count >= 2, speeds.count == points.count else { return nil }
        var best: Double?
        var startTime: Double?
        var lastStill: Double?
        let fromMS = from / 3.6
        let toMS = to / 3.6
        for i in 1..<points.count {
            let v0 = speeds[i - 1]
            let v1 = speeds[i]
            let t0 = points[i - 1].t
            let t1 = points[i].t
            if t1 - t0 > 3 {
                startTime = nil
                lastStill = nil
                continue
            }
            if from == 0 {
                if v1 < 3 / 3.6 {
                    lastStill = t1
                    startTime = nil
                    continue
                }
                if startTime == nil, let still = lastStill {
                    startTime = standingStart(still: still, index: i, points: points, speeds: speeds, launches: launches)
                    lastStill = nil
                }
            } else {
                if v0 < fromMS && v1 >= fromMS {
                    startTime = crossingTime(of: fromMS, index: i, points: points, speeds: speeds)
                } else if v1 < fromMS - 1 {
                    startTime = nil
                }
            }
            if let start = startTime, v0 < toMS, v1 >= toMS {
                let time = crossingTime(of: toMS, index: i, points: points, speeds: speeds) - start
                if time > 1.5 && time < 30 {
                    best = min(best ?? .infinity, time)
                }
                startTime = nil
            }
        }
        return best
    }

    /// Start of a launch. `index` is the first fix that moves after `still`.
    private static func standingStart(still: Double, index i: Int, points: [DrivePoint], speeds: [Double], launches: [Double]) -> Double {
        let t1 = points[i].t
        if let launch = launches.filter({ $0 >= still - 1.5 && $0 <= t1 }).max() {
            return launch
        }
        let v1 = speeds[i]
        if i + 1 < points.count {
            let dt = points[i + 1].t - t1
            let acceleration = dt > 0 ? (speeds[i + 1] - v1) / dt : 0
            if acceleration > 0.5 {
                return max(still, t1 - v1 / acceleration)
            }
        }
        return still
    }

    /// Time when the speed passed `target` between fix `index - 1` and `index`.
    private static func crossingTime(of target: Double, index i: Int, points: [DrivePoint], speeds: [Double]) -> Double {
        let t0 = points[i - 1].t
        let t1 = points[i].t
        let v0 = speeds[i - 1]
        let v1 = speeds[i]
        let linear = t0 + (target - v0) / max(v1 - v0, 0.001) * (t1 - t0)
        guard i + 1 < points.count, points[i + 1].t - t1 <= 3 else { return linear }

        // Quadratic (Lagrange) through three fixes, solved by bisection on [t0, t1].
        let t2 = points[i + 1].t
        let v2 = speeds[i + 1]
        func speed(at t: Double) -> Double {
            let l0 = (t - t1) * (t - t2) / ((t0 - t1) * (t0 - t2))
            let l1 = (t - t0) * (t - t2) / ((t1 - t0) * (t1 - t2))
            let l2 = (t - t0) * (t - t1) / ((t2 - t0) * (t2 - t1))
            return v0 * l0 + v1 * l1 + v2 * l2
        }
        guard speed(at: t0) < target, speed(at: t1) >= target else { return linear }
        var lo = t0
        var hi = t1
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if speed(at: mid) < target { lo = mid } else { hi = mid }
        }
        let result = (lo + hi) / 2
        // Fall back if the curve overshoots wildly (noisy fixes).
        return abs(result - linear) < (t1 - t0) * 0.6 ? result : linear
    }
    private static func series(_ points: [DrivePoint], speeds: [Double], start: Double) -> [SeriesPoint] {
        let all = points.indices.map { i in
            SeriesPoint(id: i, minute: (points[i].t - start) / 60, kmh: speeds[i] * 3.6, altitude: points[i].alt)
        }
        return Geo.downsample(all, maxCount: 300)
    }
}
