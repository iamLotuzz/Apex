import SwiftUI
import MapKit

struct SpeedSegment: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
}

enum RouteBuilder {
    /// Splits a route into polylines that share one speed colour.
    static func segments(speeds: [Double], coordinates: [CLLocationCoordinate2D]) -> [SpeedSegment] {
        guard coordinates.count >= 2, speeds.count == coordinates.count else { return [] }
        var result: [SpeedSegment] = []
        var current: [CLLocationCoordinate2D] = [coordinates[0]]
        var bucket = SpeedPalette.bucket(kmh: speeds[0] * 3.6)
        for i in 1..<coordinates.count {
            let b = SpeedPalette.bucket(kmh: speeds[i] * 3.6)
            current.append(coordinates[i])
            if b != bucket {
                result.append(SpeedSegment(id: result.count, coordinates: current, color: SpeedPalette.colors[bucket]))
                current = [coordinates[i]]
                bucket = b
            }
        }
        if current.count >= 2 {
            result.append(SpeedSegment(id: result.count, coordinates: current, color: SpeedPalette.colors[bucket]))
        }
        return result
    }

    static func segments(_ points: [DrivePoint], maxPoints: Int = 1500) -> [SpeedSegment] {
        let pts = Geo.downsample(points, maxCount: maxPoints)
        return segments(speeds: pts.map(\.speed), coordinates: pts.map(\.coordinate))
    }

    static func segments(_ points: [LapPoint]) -> [SpeedSegment] {
        segments(speeds: points.map(\.speed), coordinates: points.map(\.coordinate))
    }
}

struct RouteDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(radius: 2)
    }
}

struct DriveMap: View {
    let points: [DrivePoint]
    var topSpeedIndex: Int?
    /// Spike-free top speed from the analysis; the raw fix can be off.
    var topSpeed: Double?
    var interactive = true

    @State private var position: MapCameraPosition
    private let segments: [SpeedSegment]

    init(points: [DrivePoint], topSpeedIndex: Int? = nil, topSpeed: Double? = nil, interactive: Bool = true) {
        self.topSpeed = topSpeed
        self.points = points
        self.topSpeedIndex = topSpeedIndex
        self.interactive = interactive
        self.segments = RouteBuilder.segments(points)
        let rect = MapSnapshotCache.mapRect(for: points.map(\.coordinate), padding: 0.12)
        _position = State(initialValue: .rect(rect))
    }

    var body: some View {
        Map(position: $position, interactionModes: interactive ? .all : []) {
            ForEach(segments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let first = points.first {
                Annotation("Start", coordinate: first.coordinate) {
                    RouteDot(color: .green)
                }
            }
            if let last = points.last {
                Annotation("Ziel", coordinate: last.coordinate) {
                    RouteDot(color: .red)
                }
            }
            if let index = topSpeedIndex, points.indices.contains(index) {
                Annotation(Fmt.kmh(topSpeed ?? points[index].speed), coordinate: points[index].coordinate, anchor: .bottom) {
                    Image(systemName: "bolt.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.purple, in: .circle)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
    }
}
