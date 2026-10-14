import Foundation
import SwiftData
import CoreLocation

/// One GPS fix of a recorded drive.
struct DrivePoint: Equatable {
    var t: Double          // seconds since reference date
    var lat: Double
    var lon: Double
    var alt: Double        // metres
    var speed: Double      // m/s
    var course: Double     // degrees, -1 when invalid
    var accuracy: Double   // horizontal accuracy in metres

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var date: Date { Date(timeIntervalSinceReferenceDate: t) }

    init(t: Double, lat: Double, lon: Double, alt: Double, speed: Double, course: Double, accuracy: Double) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.alt = alt
        self.speed = speed
        self.course = course
        self.accuracy = accuracy
    }

    init(location: CLLocation, speed: Double) {
        self.init(
            t: location.timestamp.timeIntervalSinceReferenceDate,
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            alt: location.altitude,
            speed: max(0, speed),
            course: location.course,
            accuracy: location.horizontalAccuracy
        )
    }

    private static let stride = 7

    /// Packs the points as raw doubles (56 bytes per point).
    static func encode(_ points: [DrivePoint]) -> Data {
        var values = [Double]()
        values.reserveCapacity(points.count * stride)
        for p in points {
            values.append(contentsOf: [p.t, p.lat, p.lon, p.alt, p.speed, p.course, p.accuracy])
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [DrivePoint] {
        let count = data.count / MemoryLayout<Double>.size
        guard count >= stride else { return [] }
        var values = [Double](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        var points = [DrivePoint]()
        points.reserveCapacity(count / stride)
        var i = 0
        while i + stride <= count {
            points.append(DrivePoint(
                t: values[i], lat: values[i + 1], lon: values[i + 2], alt: values[i + 3],
                speed: values[i + 4], course: values[i + 5], accuracy: values[i + 6]
            ))
            i += stride
        }
        return points
    }
}

enum DoublePacking {
    static func encode(_ values: [Double]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Double] {
        let count = data.count / MemoryLayout<Double>.size
        guard count > 0 else { return [] }
        var values = [Double](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }
}

@Model
final class Drive {
    var id: UUID = UUID()
    var startDate: Date = Date()
    var endDate: Date = Date()
    var title: String = ""
    var startPlace: String?
    var endPlace: String?
    var isFavorite: Bool = false
    var isManual: Bool = false
    var carID: UUID?

    // Summary values, cached for lists and totals.
    var distance: Double = 0        // metres
    var movingTime: Double = 0      // seconds
    var maxSpeed: Double = 0        // m/s
    var avgSpeed: Double = 0        // m/s over the whole duration
    var elevationGain: Double = 0   // metres

    var temperature: Double?
    var weatherCode: Int?

    @Attribute(.externalStorage) var pointsData: Data = Data()
    /// Launch moments from the accelerometer (seconds since reference date).
    var launchData: Data = Data()

    init(
        startDate: Date,
        endDate: Date,
        points: [DrivePoint],
        launches: [Double] = [],
        isManual: Bool = false,
        carID: UUID? = nil
    ) {
        self.id = UUID()
        self.startDate = startDate
        self.endDate = endDate
        self.isManual = isManual
        self.carID = carID
        self.pointsData = DrivePoint.encode(points)
        self.launchData = DoublePacking.encode(launches)
        applySummary(DriveAnalyzer.analyze(points, launches: launches))
    }

    var points: [DrivePoint] { DrivePoint.decode(pointsData) }

    var launches: [Double] { DoublePacking.decode(launchData) }

    var duration: Double { endDate.timeIntervalSince(startDate) }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let endPlace, let startPlace, endPlace != startPlace {
            return "\(startPlace) → \(endPlace)"
        }
        if let endPlace { return "Fahrt in \(endPlace)" }
        return "Fahrt am \(startDate.formatted(.dateTime.weekday(.wide)))"
    }

    func applySummary(_ stats: DriveStats) {
        distance = stats.distance
        movingTime = stats.movingTime
        maxSpeed = stats.maxSpeed
        avgSpeed = stats.avgSpeed
        elevationGain = stats.elevationGain
    }
}
