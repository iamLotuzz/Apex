import Foundation
import CoreLocation

/// Cleans the raw GPS track of a drive.
///
/// - Drops fixes that are too inaccurate or that jump farther than the car
///   could have moved since the last fix.
/// - Holds the position still while the car stands (GPS drifts a few metres
///   at a standstill, which made the route zig-zag at traffic lights).
/// - Blends each position with a prediction from the Doppler velocity, which
///   is far more precise than a single position.
struct GPSFilter {
    /// Fixes worse than this are ignored entirely.
    static let maxAccuracy = 25.0

    private var projection: LocalProjection?
    private var state: (xy: Vec2, time: Date, velocity: Vec2?)?

    /// Returns the cleaned coordinate, or nil when the fix should be skipped.
    mutating func process(_ location: CLLocation) -> CLLocationCoordinate2D? {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= Self.maxAccuracy else { return nil }
        if projection == nil {
            projection = LocalProjection(origin: location.coordinate)
        }
        guard let projection else { return nil }

        let raw = projection.point(location.coordinate)
        let time = location.timestamp
        let velocity = Self.velocity(location)

        guard let previous = state else {
            state = (raw, time, velocity)
            return location.coordinate
        }
        let dt = time.timeIntervalSince(previous.time)
        guard dt > 0 else { return nil }
        if dt > 15 {
            // Long gap (tunnel, app paused): start fresh.
            state = (raw, time, velocity)
            return location.coordinate
        }

        // A real car cannot move farther than its speed allows plus the GPS error.
        let speedBound = max(location.speed, 0) + 6
        let allowed = speedBound * dt + 2 * location.horizontalAccuracy + 5
        if (raw - previous.xy).length > allowed {
            return nil
        }

        // Standing still: keep the last position instead of following GPS drift.
        if location.speed >= 0 && location.speed < 0.8 {
            state = (previous.xy, time, nil)
            return projection.coordinate(previous.xy)
        }

        guard let velocity, let previousVelocity = previous.velocity else {
            state = (raw, time, velocity)
            return location.coordinate
        }
        let predicted = previous.xy + (previousVelocity + velocity) * (0.5 * dt)
        let speedSigma = location.speedAccuracy >= 0 ? location.speedAccuracy : 0.5
        let predictionSigma = 0.5 + speedSigma * dt
        let measurementSigma = max(2, location.horizontalAccuracy * 0.6)
        let p2 = predictionSigma * predictionSigma
        let gain = min(1, max(0.2, p2 / (p2 + measurementSigma * measurementSigma)))
        let result = predicted + (raw - predicted) * gain
        state = (result, time, velocity)
        return projection.coordinate(result)
    }

    private static func velocity(_ location: CLLocation) -> Vec2? {
        guard location.speed > 2, location.course >= 0 else { return nil }
        if location.courseAccuracy >= 0 && location.courseAccuracy > 25 { return nil }
        let radians = location.course * .pi / 180
        return Vec2(x: location.speed * sin(radians), y: location.speed * cos(radians))
    }
}
