import Foundation
import CoreLocation

/// One rally pace note: direction and grade of a corner on the route.
/// Grades follow the usual rally scale: 1 is the tightest, 6 almost flat;
/// grade 0 is a hairpin.
struct RallyNote: Identifiable, Equatable {
    let id: Int
    /// Distance along the route where the corner starts.
    let along: Double
    /// Distance along the route where the corner ends.
    let end: Double
    /// -1 left, +1 right.
    let direction: Int
    let grade: Int
    let long: Bool
    /// The corner is a turn at a junction that the directions also announce.
    var atManeuver = false

    /// Shown on screen: "Rechts 4 lang", "Haarnadel links".
    var display: String {
        let side = direction < 0 ? "Links" : "Rechts"
        if grade == 0 { return "Haarnadel \(side.lowercased())" }
        return long ? "\(side) \(grade) lang" : "\(side) \(grade)"
    }

    /// Spoken with number words, so every voice says "Rechts vier" and not
    /// "Rechts vierte" or a spelled digit.
    var spoken: String {
        let side = direction < 0 ? "Links" : "Rechts"
        if grade == 0 { return "Haarnadel \(side.lowercased())" }
        let words = ["null", "eins", "zwei", "drei", "vier", "fünf", "sechs"]
        let number = words.indices.contains(grade) ? words[grade] : String(grade)
        return long ? "\(side) \(number) lang" : "\(side) \(number)"
    }

    var short: String {
        (direction < 0 ? "L" : "R") + (grade == 0 ? "H" : String(grade))
    }

    var symbol: String {
        if grade <= 2 { return direction < 0 ? "arrow.turn.up.left" : "arrow.turn.up.right" }
        return direction < 0 ? "arrow.up.left" : "arrow.up.right"
    }
}

/// Builds pace notes from a route polyline.
///
/// The route is resampled every 10 m. A corner is a run of samples that all
/// turn the same way faster than ~2.5° per 10 m (a radius under ~230 m).
/// Its radius (length / angle) gives the grade. Corners within 50 m of a
/// turn instruction are kept as well (marked `atManeuver`), so the pace
/// notes never go quiet; they are called after the direction there.
enum RallyNoteBuilder {
    static func notes(coordinates: [CLLocationCoordinate2D], cumulative: [Double], maneuvers: [Double]) -> [RallyNote] {
        guard coordinates.count >= 2, let total = cumulative.last, total > 50 else { return [] }
        let step = 10.0
        var samples: [CLLocationCoordinate2D] = []
        var segment = 0
        var s = 0.0
        while s <= total {
            while segment < cumulative.count - 2 && cumulative[segment + 1] < s { segment += 1 }
            let a = coordinates[segment]
            let b = coordinates[segment + 1]
            let span = cumulative[segment + 1] - cumulative[segment]
            let f = span > 0 ? (s - cumulative[segment]) / span : 0
            samples.append(CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * f,
                longitude: a.longitude + (b.longitude - a.longitude) * f
            ))
            s += step
        }
        guard samples.count >= 4 else { return [] }

        var headings: [Double] = []
        for i in 0..<(samples.count - 1) {
            let p = LocalProjection(origin: samples[i]).point(samples[i + 1])
            headings.append(atan2(p.x, p.y) * 180 / .pi)
        }
        var turn = [Double](repeating: 0, count: headings.count)
        for i in 1..<headings.count {
            var d = headings[i] - headings[i - 1]
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            turn[i] = d
        }
        // Light smoothing against polyline corners.
        var smooth = turn
        for i in 1..<(turn.count - 1) {
            smooth[i] = (turn[i - 1] + turn[i] * 2 + turn[i + 1]) / 4
        }

        var notes: [RallyNote] = []
        var i = 1
        while i < smooth.count {
            guard abs(smooth[i]) > 2.5 else { i += 1; continue }
            let sign = smooth[i] > 0 ? 1.0 : -1.0
            let start = i
            var angle = 0.0
            var gap = 0
            while i < smooth.count {
                if smooth[i] * sign > 1.0 {
                    angle += smooth[i]
                    gap = 0
                } else {
                    gap += 1
                    if gap > 1 { break }
                }
                i += 1
            }
            let length = Double(i - start - gap) * step
            let degrees = abs(angle)
            guard degrees >= 25, length > 0 else { continue }
            let radius = length / (degrees * .pi / 180)
            let grade: Int
            switch radius {
            case ..<20: grade = 0
            case ..<35: grade = 1
            case ..<55: grade = 2
            case ..<85: grade = 3
            case ..<130: grade = 4
            case ..<200: grade = 5
            default: grade = 6
            }
            let along = Double(start) * step
            notes.append(RallyNote(
                id: notes.count,
                along: along,
                end: along + length,
                direction: sign < 0 ? -1 : 1,
                grade: grade,
                long: degrees > 120 && length > 80,
                atManeuver: maneuvers.contains { abs($0 - along) < 50 }
            ))
        }
        return notes
    }
}
