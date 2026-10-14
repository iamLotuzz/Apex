import Foundation
import CoreLocation
import SwiftData

/// Sample drives and a sample track session, so every screen can be checked
/// before the first real drive.
@MainActor
enum DemoData {
    static func generate(around center: CLLocationCoordinate2D) {
        let context = Persistence.context
        var generator = SystemRandomNumberGenerator()
        let carID = Persistence.activeCar()?.id
        var carIDs: [UUID?] = [carID]
        let carCount = (try? context.fetchCount(FetchDescriptor<Car>())) ?? 0
        if carCount < 2 {
            // A second car shows how drives split between cars.
            let second = Car(nickname: "Alltagsauto")
            second.consumption = 5.9
            second.fuelTypeRaw = FuelType.diesel.rawValue
            context.insert(second)
            carIDs.append(second.id)
        }

        for k in 0..<6 {
            let start = Date().addingTimeInterval(-Double(k) * 86_400 * 1.6 - Double.random(in: 3_600...30_000, using: &generator))
            let points = drivePoints(
                from: offset(center, north: Double.random(in: -3000...3000), east: Double.random(in: -3000...3000)),
                start: start,
                seconds: Int.random(in: 600...2_400),
                using: &generator
            )
            guard let first = points.first, let last = points.last else { continue }
            let drive = Drive(startDate: first.date, endDate: last.date, points: points, carID: carIDs[k % carIDs.count])
            drive.title = ["Feierabendrunde", "Zum Bäcker", "Landstraße", "Autobahn-Etappe", "Sonntagsausfahrt", "Nachtfahrt"][k]
            drive.temperature = Double.random(in: 4...24, using: &generator)
            drive.weatherCode = [0, 2, 3, 61, 1, 0][k]
            context.insert(drive)
        }

        let trackCenter = offset(center, north: 1500, east: -2000)
        let a = offset(trackCenter, north: 0, east: 380)
        let b = offset(trackCenter, north: 0, east: 440)
        let track = Track(name: "Demo-Ring", kind: .circuit, startA: Coordinate(a), startB: Coordinate(b))
        context.insert(track)

        let timer = LapTimer(track: track.snapshot, reference: .previous)
        let sessionStart = Date().addingTimeInterval(-86_400 * 2)
        var time = sessionStart
        let laps = 6
        let samplesPerLap = 95
        var angle = -0.25
        for lap in 0...laps {
            let lapFactor = 1.0 + Double.random(in: -0.04...0.05, using: &generator) - (lap == 4 ? 0.05 : 0)
            for _ in 0..<samplesPerLap {
                let speed = (32 + 10 * cos(angle * 2)) / lapFactor
                angle += (2 * .pi) / Double(samplesPerLap)
                time = time.addingTimeInterval(1)
                let c = offset(trackCenter, north: 260 * sin(angle), east: 410 * cos(angle))
                let location = CLLocation(
                    coordinate: c,
                    altitude: 400,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5,
                    course: -1,
                    speed: speed,
                    timestamp: time
                )
                timer.process(location)
            }
        }
        if !timer.laps.isEmpty {
            let session = TrackSession(track: track.snapshot, date: sessionStart, endDate: time, laps: timer.laps, carID: carID)
            context.insert(session)
            track.bestLapTime = session.bestLapTime
            track.lapLength = timer.bestLap?.distance
        }
        Persistence.save()
    }

    private static func drivePoints(from origin: CLLocationCoordinate2D, start: Date, seconds: Int, using generator: inout SystemRandomNumberGenerator) -> [DrivePoint] {
        var points: [DrivePoint] = []
        var position = origin
        var heading = Double.random(in: 0..<360, using: &generator)
        var speed = 0.0
        var target = 14.0
        var altitude = Double.random(in: 80...400, using: &generator)
        var nextChange = 0
        for s in 0..<seconds {
            if s >= nextChange {
                let options: [Double] = [0, 8, 14, 19, 25, 28, 36, 40]
                target = options.randomElement(using: &generator) ?? 14
                nextChange = s + Int.random(in: 25...120, using: &generator)
            }
            let accel = target > speed ? min(3.2, target - speed) : max(-5, target - speed)
            speed = max(0, speed + accel)
            heading += Double.random(in: -6...6, using: &generator) * (speed > 25 ? 0.3 : 1)
            let distance = speed
            position = offset(
                position,
                north: distance * cos(heading * .pi / 180),
                east: distance * sin(heading * .pi / 180)
            )
            altitude += Double.random(in: -0.6...0.6, using: &generator) + sin(Double(s) / 90) * 0.4
            points.append(DrivePoint(
                t: start.addingTimeInterval(Double(s)).timeIntervalSinceReferenceDate,
                lat: position.latitude,
                lon: position.longitude,
                alt: altitude,
                speed: speed,
                course: heading.truncatingRemainder(dividingBy: 360) < 0 ? heading.truncatingRemainder(dividingBy: 360) + 360 : heading.truncatingRemainder(dividingBy: 360),
                accuracy: 6
            ))
        }
        return points
    }

    static func offset(_ c: CLLocationCoordinate2D, north: Double, east: Double) -> CLLocationCoordinate2D {
        let dLat = north / 111_320
        let dLon = east / (111_320 * cos(c.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }
}

@MainActor
enum SessionStore {
    /// Saves a finished live session and updates the track's best lap.
    @discardableResult
    static func save(timer: LapTimer, track: Track?) -> TrackSession? {
        guard !timer.laps.isEmpty else { return nil }
        let session = TrackSession(track: timer.track, date: timer.sessionStart, endDate: Date(), laps: timer.laps, carID: Persistence.activeCar()?.id)
        Persistence.context.insert(session)
        if let track, let best = session.bestLapTime {
            if track.bestLapTime.map({ best < $0 }) ?? true {
                track.bestLapTime = best
                track.lapLength = timer.bestLap?.distance
            }
        }
        Persistence.save()
        return session
    }
}
