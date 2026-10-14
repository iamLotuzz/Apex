import Foundation
import SwiftData
import CoreLocation

enum TrackKind: String, CaseIterable, Identifiable, Codable {
    case circuit
    case sprint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circuit: return "Rundkurs"
        case .sprint: return "Sprint (A → B)"
        }
    }
}

struct Coordinate: Codable, Hashable {
    var lat: Double
    var lon: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    init(_ c: CLLocationCoordinate2D) {
        lat = c.latitude
        lon = c.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

@Model
final class Track {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = TrackKind.circuit.rawValue
    var createdAt: Date = Date()
    var startA: Coordinate = Coordinate(lat: 0, lon: 0)
    var startB: Coordinate = Coordinate(lat: 0, lon: 0)
    var finishA: Coordinate?
    var finishB: Coordinate?
    var bestLapTime: Double?
    var lapLength: Double?

    init(name: String, kind: TrackKind, startA: Coordinate, startB: Coordinate, finishA: Coordinate? = nil, finishB: Coordinate? = nil) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.createdAt = Date()
        self.startA = startA
        self.startB = startB
        self.finishA = finishA
        self.finishB = finishB
    }

    var kind: TrackKind {
        get { TrackKind(rawValue: kindRaw) ?? .circuit }
        set { kindRaw = newValue.rawValue }
    }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (startA.lat + startB.lat) / 2,
            longitude: (startA.lon + startB.lon) / 2
        )
    }

    var snapshot: TrackSnapshot {
        TrackSnapshot(
            id: id, name: name, kind: kind,
            startA: startA, startB: startB,
            finishA: finishA, finishB: finishB
        )
    }
}

/// A value copy of a track, used while a session runs.
struct TrackSnapshot: Identifiable, Hashable {
    var id: UUID
    var name: String
    var kind: TrackKind
    var startA: Coordinate
    var startB: Coordinate
    var finishA: Coordinate?
    var finishB: Coordinate?
}

/// One GPS fix inside a lap. `t` is seconds since the lap started.
struct LapPoint: Codable, Hashable {
    var t: Double
    var lat: Double
    var lon: Double
    var speed: Double   // m/s

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

struct Lap: Codable, Identifiable, Hashable {
    var number: Int
    var duration: Double
    var distance: Double
    var maxSpeed: Double
    var avgSpeed: Double
    var points: [LapPoint]

    var id: Int { number }
}

@Model
final class TrackSession {
    var id: UUID = UUID()
    var trackID: UUID = UUID()
    var trackName: String = ""
    var date: Date = Date()
    var endDate: Date = Date()
    var lapCount: Int = 0
    var bestLapTime: Double?
    var maxSpeed: Double = 0
    var totalDistance: Double = 0
    var carID: UUID?
    @Attribute(.externalStorage) var lapsData: Data = Data()

    init(track: TrackSnapshot, date: Date, endDate: Date, laps: [Lap], carID: UUID? = nil) {
        self.id = UUID()
        self.carID = carID
        self.trackID = track.id
        self.trackName = track.name
        self.date = date
        self.endDate = endDate
        setLaps(laps)
    }

    var laps: [Lap] {
        (try? JSONDecoder().decode([Lap].self, from: lapsData)) ?? []
    }

    func setLaps(_ laps: [Lap]) {
        lapsData = (try? JSONEncoder().encode(laps)) ?? Data()
        lapCount = laps.count
        bestLapTime = laps.map(\.duration).min()
        maxSpeed = laps.map(\.maxSpeed).max() ?? 0
        totalDistance = laps.reduce(0) { $0 + $1.distance }
    }
}
