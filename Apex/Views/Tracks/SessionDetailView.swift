import SwiftUI
import SwiftData
import MapKit
import Charts

struct SessionDetailView: View {
    let session: TrackSession

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var tracks: [Track]
    @Query private var cars: [Car]

    @State private var laps: [Lap] = []
    @State private var selectedLap: Int?
    @State private var showDelete = false

    private var bestLap: Lap? { laps.min { $0.duration < $1.duration } }

    private var shownLap: Lap? {
        if let selectedLap, let lap = laps.first(where: { $0.number == selectedLap }) { return lap }
        return bestLap
    }

    private var averageLap: Double {
        guard !laps.isEmpty else { return 0 }
        return laps.reduce(0.0) { $0 + $1.duration } / Double(laps.count)
    }

    /// Standard deviation of the lap times.
    private var consistency: Double {
        guard laps.count >= 2 else { return 0 }
        let mean = averageLap
        let variance = laps.reduce(0.0) { $0 + pow($1.duration - mean, 2) } / Double(laps.count - 1)
        return variance.squareRoot()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if !laps.isEmpty {
                    StatGrid {
                        StatTile(title: "Runden", value: "\(laps.count)", symbol: "arrow.triangle.2.circlepath", tint: .blue)
                        StatTile(title: "Ø Runde", value: Fmt.lap(averageLap), symbol: "timer", tint: .orange)
                        StatTile(title: "Konstanz", value: "±\(Fmt.number(consistency, digits: 2))", unit: "s", symbol: "waveform.path.ecg", tint: .green)
                        StatTile(title: "Höchsttempo", value: Fmt.kmhValue(session.maxSpeed), unit: "km/h", symbol: "bolt.fill", tint: .red)
                        StatTile(title: "Distanz", value: Fmt.km(session.totalDistance, digits: 1), unit: "km", symbol: "road.lanes", tint: .teal)
                        StatTile(title: "Dauer", value: Fmt.clock(session.endDate.timeIntervalSince(session.date)), symbol: "clock", tint: .gray)
                    }
                    lapChart
                    lapMap
                    speedTrace
                    lapList
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle(session.trackName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showDelete = true
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Session löschen?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { deleteSession() }
        }
        .task {
            if laps.isEmpty { laps = session.laps }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("BESTE RUNDE")
                .font(.caption.weight(.heavy))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            Text(bestLap.map { Fmt.lap($0.duration) } ?? "–")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.purple)
            Text("\(session.date.formatted(date: .complete, time: .shortened))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let best = bestLap {
                Text("Runde \(best.number) · Ø \(Fmt.kmh(best.avgSpeed)) · max. \(Fmt.kmh(best.maxSpeed))")
                    .font(.subheadline.weight(.medium))
            }
            if let car = cars.first(where: { $0.id == session.carID }) {
                HStack(spacing: 8) {
                    PixelImage(image: car.frontImage)
                        .frame(width: 34, height: 20)
                    Text(car.displayName)
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var lapChart: some View {
        let durations = laps.map(\.duration)
        let lo = (durations.min() ?? 0) - 1
        let hi = (durations.max() ?? 1) + 1
        return Card(title: "Rundenzeiten", symbol: "chart.bar.xaxis") {
            Chart {
                ForEach(laps) { lap in
                    BarMark(x: .value("Runde", "\(lap.number)"), yStart: .value("Basis", lo), yEnd: .value("Zeit", lap.duration))
                        .foregroundStyle(lap.number == bestLap?.number ? Color.purple : (lap.number == shownLap?.number ? Color.orange : Color.gray.opacity(0.5)))
                        .cornerRadius(6)
                }
                RuleMark(y: .value("Ø", averageLap))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartYScale(domain: lo...hi)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(Fmt.lap(seconds, digits: 1))
                        }
                    }
                }
            }
            .frame(height: 190)
            Text("Tippe unten auf eine Runde, um sie auf Karte und Tempo-Kurve zu sehen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var lapMap: some View {
        if let lap = shownLap {
            Card(title: "Runde \(lap.number) auf der Karte", symbol: "map") {
                SessionLapMap(lap: lap, track: tracks.first { $0.id == session.trackID })
                    .id(lap.number)
                    .frame(height: 260)
                    .clipShape(.rect(cornerRadius: 18))
                HStack(spacing: 6) {
                    ForEach(Array(SpeedPalette.colors.enumerated()), id: \.offset) { index, color in
                        HStack(spacing: 3) {
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text("\(Int(SpeedPalette.edges[index]))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("km/h")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct TracePoint: Identifiable {
        let id: String
        let distance: Double
        let kmh: Double
        let series: String
    }

    private func trace(for lap: Lap, name: String) -> [TracePoint] {
        var distance = 0.0
        var result: [TracePoint] = []
        for (i, p) in lap.points.enumerated() {
            if i > 0 { distance += Geo.distance(lap.points[i - 1].coordinate, p.coordinate) }
            result.append(TracePoint(id: "\(name)-\(i)", distance: distance, kmh: p.speed * 3.6, series: name))
        }
        return result
    }

    @ViewBuilder
    private var speedTrace: some View {
        if let best = bestLap {
            let selected = shownLap
            let points = trace(for: best, name: "Beste (R\(best.number))")
                + ((selected != nil && selected?.number != best.number) ? trace(for: selected!, name: "Runde \(selected!.number)") : [])
            Card(title: "Tempo über die Runde", symbol: "chart.xyaxis.line") {
                Chart(points) { p in
                    LineMark(
                        x: .value("Meter", p.distance),
                        y: .value("km/h", p.kmh),
                        series: .value("Runde", p.series)
                    )
                    .foregroundStyle(p.series.hasPrefix("Beste") ? Color.purple : Color.orange)
                    .interpolationMethod(.monotone)
                }
                .chartXAxisLabel("Meter")
                .chartYAxisLabel("km/h")
                .frame(height: 200)
                HStack(spacing: 14) {
                    Label("Beste Runde", systemImage: "circle.fill")
                        .foregroundStyle(.purple)
                    if let selected, selected.number != best.number {
                        Label("Runde \(selected.number)", systemImage: "circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    private var lapList: some View {
        let best = bestLap?.duration ?? 0
        return Card(title: "Alle Runden", symbol: "list.number") {
            VStack(spacing: 0) {
                ForEach(laps) { lap in
                    Button {
                        withAnimation(.snappy) { selectedLap = lap.number }
                    } label: {
                        HStack {
                            Text("R\(lap.number)")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 40, alignment: .leading)
                            Text(Fmt.lap(lap.duration))
                                .font(.system(.body, design: .rounded).weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(lap.duration == best ? Color.purple : Color.primary)
                            Spacer()
                            if lap.duration == best {
                                Image(systemName: "trophy.fill").foregroundStyle(.purple)
                            } else {
                                Text(Fmt.delta(lap.duration - best, digits: 3))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.red)
                            }
                            Text(Fmt.kmh(lap.maxSpeed))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 8)
                        .background(lap.number == shownLap?.number ? Color.orange.opacity(0.15) : Color.clear, in: .rect(cornerRadius: 10))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func deleteSession() {
        let target = session
        let trackID = session.trackID
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            context.delete(target)
            try? context.save()
            let remaining = (try? context.fetch(FetchDescriptor<TrackSession>(predicate: #Predicate<TrackSession> { $0.trackID == trackID }))) ?? []
            if let track = tracks.first(where: { $0.id == trackID }) {
                track.bestLapTime = remaining.compactMap(\.bestLapTime).min()
                try? context.save()
            }
        }
    }
}

struct SessionLapMap: View {
    let lap: Lap
    let track: Track?
    @State private var position: MapCameraPosition

    init(lap: Lap, track: Track?) {
        self.lap = lap
        self.track = track
        _position = State(initialValue: .rect(MapSnapshotCache.mapRect(for: lap.points.map(\.coordinate), padding: 0.08)))
    }

    var body: some View {
        Map(position: $position) {
            ForEach(RouteBuilder.segments(lap.points)) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let track {
                MapPolyline(coordinates: [track.startA.clCoordinate, track.startB.clCoordinate])
                    .stroke(.white, style: StrokeStyle(lineWidth: 5, dash: [5, 5]))
            }
            if let top = lap.points.max(by: { $0.speed < $1.speed }) {
                Annotation(Fmt.kmh(top.speed), coordinate: top.coordinate, anchor: .bottom) {
                    Image(systemName: "bolt.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.purple, in: .circle)
                }
            }
        }
        .mapStyle(.hybrid(elevation: .realistic))
    }
}
