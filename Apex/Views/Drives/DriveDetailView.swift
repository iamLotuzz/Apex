import SwiftUI
import SwiftData
import Charts

struct DriveDetailView: View {
    let drive: Drive

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var cars: [Car]

    @State private var points: [DrivePoint] = []
    @State private var stats: DriveStats?
    @State private var showDelete = false
    @State private var showRename = false
    @State private var newTitle = ""
    @State private var gpxURL: URL?
    @State private var showFullMap = false

    private var car: Car? {
        cars.first { $0.id == drive.carID } ?? cars.first(where: \.isActive) ?? cars.first
    }

    /// The car this drive belongs to; editable from the toolbar menu.
    private var carSelection: Binding<UUID?> {
        Binding(
            get: { drive.carID },
            set: { newValue in
                drive.carID = newValue
                try? context.save()
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                mapHeader
                titleBlock
                if let stats {
                    overview(stats)
                    speedChart(stats)
                    dynamics(stats)
                    distribution(stats)
                    elevation(stats)
                    costs(stats)
                    if drive.temperature != nil || drive.weatherCode != nil {
                        weather
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle(drive.startDate.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            guard stats == nil else { return }
            let loaded = drive.points
            points = loaded
            let analyzed = DriveAnalyzer.analyze(loaded, launches: drive.launches)
            stats = analyzed
            // Older drives were summarised with the previous analysis (e.g.
            // a Doppler spike as top speed): bring the list values up to date.
            if abs(drive.maxSpeed - analyzed.maxSpeed) > 0.05 || abs(drive.distance - analyzed.distance) > 1 {
                drive.applySummary(analyzed)
                try? context.save()
            }
            gpxURL = GPXExporter.export(name: drive.displayTitle, points: loaded)
        }
        .alert("Fahrt umbenennen", isPresented: $showRename) {
            TextField("Name", text: $newTitle)
            Button("Sichern") {
                drive.title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                try? context.save()
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Fahrt löschen?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { deleteDrive() }
        } message: {
            Text("Die Fahrt und ihre Strecke werden entfernt.")
        }
        .fullScreenCover(isPresented: $showFullMap) {
            NavigationStack {
                DriveMap(points: points, topSpeedIndex: stats?.maxSpeedIndex, topSpeed: stats?.maxSpeed)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(drive.displayTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fertig") { showFullMap = false }
                        }
                    }
            }
        }
    }

    // MARK: Sections

    private var mapHeader: some View {
        ZStack(alignment: .bottom) {
            if points.count >= 2 {
                DriveMap(points: points, topSpeedIndex: stats?.maxSpeedIndex, topSpeed: stats?.maxSpeed, interactive: false)
                    .onTapGesture { showFullMap = true }
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(ProgressView())
            }

            HStack(spacing: 0) {
                MiniStat(value: Fmt.km(drive.distance), caption: "km")
                MiniStat(value: Fmt.clock(drive.duration), caption: "Dauer")
                MiniStat(value: Fmt.kmhValue(drive.avgSpeed), caption: "Ø km/h")
                MiniStat(value: Fmt.kmhValue(drive.maxSpeed), caption: "max. km/h")
            }
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(10)
        }
        .frame(height: 340)
        .clipShape(.rect(cornerRadius: 28))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.footnote.bold())
                .padding(10)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(12)
                .onTapGesture { showFullMap = true }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(drive.displayTitle)
                .font(.title2.bold())
            Text("\(drive.startDate.formatted(.dateTime.weekday(.wide).day().month(.wide))) · \(Fmt.time(drive.startDate)) – \(Fmt.time(drive.endDate))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if drive.isManual {
                Label("Manuell gestartet", systemImage: "hand.tap")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let assigned = cars.first(where: { $0.id == drive.carID }) {
                HStack(spacing: 8) {
                    PixelImage(image: assigned.frontImage)
                        .frame(width: 34, height: 20)
                    Text(assigned.displayName)
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func overview(_ s: DriveStats) -> some View {
        StatGrid {
            StatTile(title: "Strecke", value: Fmt.km(s.distance, digits: 2), unit: "km", symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: .orange)
            StatTile(title: "Dauer", value: Fmt.clock(s.duration), symbol: "clock", tint: .blue)
            StatTile(title: "In Bewegung", value: Fmt.clock(s.movingTime), symbol: "figure.run", tint: .green)
            StatTile(title: "Standzeit", value: Fmt.clock(s.stoppedTime), unit: "\(s.stopCount)× gestoppt", symbol: "pause.circle", tint: .gray)
            StatTile(title: "Ø Tempo", value: Fmt.kmhValue(s.avgSpeed), unit: "km/h", symbol: "speedometer", tint: .teal)
            StatTile(title: "Ø in Bewegung", value: Fmt.kmhValue(s.avgMovingSpeed), unit: "km/h", symbol: "speedometer", tint: .cyan)
            StatTile(title: "Höchsttempo", value: Fmt.kmhValue(s.maxSpeed), unit: "km/h", symbol: "bolt.fill", tint: .purple)
            StatTile(title: "Über 100 km/h", value: Fmt.clock(s.timeAbove100), unit: s.timeAbove130 > 0 ? "130+: \(Fmt.clock(s.timeAbove130))" : "", symbol: "gauge.with.dots.needle.100percent", tint: .red)
        }
    }

    private func speedChart(_ s: DriveStats) -> some View {
        Card(title: "Geschwindigkeit", symbol: "chart.xyaxis.line") {
            Chart {
                ForEach(s.series) { p in
                    AreaMark(x: .value("Minute", p.minute), y: .value("km/h", p.kmh))
                        .foregroundStyle(LinearGradient(colors: [.orange.opacity(0.35), .orange.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Minute", p.minute), y: .value("km/h", p.kmh))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Ø", s.avgMovingSpeed * 3.6))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Ø \(Fmt.kmhValue(s.avgMovingSpeed))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
            .chartXAxisLabel("Minuten")
            .chartYAxisLabel("km/h")
            .frame(height: 190)
        }
    }

    private func dynamics(_ s: DriveStats) -> some View {
        Card(title: "Fahrdynamik", symbol: "gauge.open.with.lines.needle.33percent.and.arrowtriangle") {
            StatGrid {
                StatTile(title: "0–50 km/h", value: Fmt.seconds(s.zeroTo50), symbol: "flag", tint: .green)
                StatTile(title: "0–100 km/h", value: Fmt.seconds(s.zeroTo100), symbol: "flag.checkered", tint: .orange)
                StatTile(title: "80–120 km/h", value: Fmt.seconds(s.eightyTo120), symbol: "arrow.up.right", tint: .red)
                StatTile(title: "Max. Beschl.", value: Fmt.g(s.maxAcceleration), symbol: "arrow.up.forward.circle", tint: .mint)
                StatTile(title: "Max. Bremsen", value: Fmt.g(s.maxDeceleration), symbol: "exclamationmark.brakesignal", tint: .pink)
                StatTile(title: "Kurven", value: s.curvatureLabel, unit: "\(Int(s.curvature))°/km", symbol: "point.bottomleft.forward.to.arrow.triangle.scurvepath", tint: .indigo)
            }
            Text("Start über den Beschleunigungssensor (50 Hz), Zielgeschwindigkeit über eine Kurve durch die GPS-Messungen. Genauigkeit etwa ±0,1 s.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func distribution(_ s: DriveStats) -> some View {
        Card(title: "Tempo-Verteilung", symbol: "chart.bar.fill") {
            Chart(s.buckets) { bucket in
                BarMark(x: .value("km/h", bucket.label), y: .value("Minuten", bucket.seconds / 60))
                    .foregroundStyle(SpeedPalette.color(kmh: bucket.lower + 1))
                    .cornerRadius(6)
            }
            .chartYAxisLabel("Minuten")
            .frame(height: 160)
        }
    }

    private func elevation(_ s: DriveStats) -> some View {
        Card(title: "Höhenprofil", symbol: "mountain.2.fill") {
            Chart(s.series) { p in
                AreaMark(x: .value("Minute", p.minute), y: .value("Höhe", p.altitude))
                    .foregroundStyle(LinearGradient(colors: [.teal.opacity(0.4), .teal.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel("m")
            .frame(height: 130)
            StatGrid {
                StatTile(title: "Anstieg", value: "\(Int(s.elevationGain))", unit: "m", symbol: "arrow.up.right", tint: .teal)
                StatTile(title: "Abstieg", value: "\(Int(s.elevationLoss))", unit: "m", symbol: "arrow.down.right", tint: .teal)
                StatTile(title: "Tiefster Punkt", value: s.minAltitude.map { "\(Int($0))" } ?? "–", unit: "m", symbol: "arrow.down.to.line", tint: .brown)
                StatTile(title: "Höchster Punkt", value: s.maxAltitude.map { "\(Int($0))" } ?? "–", unit: "m", symbol: "arrow.up.to.line", tint: .brown)
            }
        }
    }

    @ViewBuilder
    private func costs(_ s: DriveStats) -> some View {
        if let car, let consumption = car.consumption, consumption > 0 {
            let litres = s.distance / 1000 * consumption / 100
            Card(title: "Verbrauch (geschätzt)", symbol: "fuelpump.fill") {
                StatGrid {
                    StatTile(title: "Kraftstoff", value: Fmt.number(litres, digits: 1), unit: "l", symbol: "drop.fill", tint: .orange)
                    if let price = SharedStore.lastCheapestPrice {
                        StatTile(title: "Kosten", value: Fmt.euro(litres * price), symbol: "eurosign.circle", tint: .green)
                    }
                    StatTile(title: "CO₂", value: Fmt.number(litres * car.fuelType.co2PerLitre, digits: 1), unit: "kg", symbol: "leaf.fill", tint: .mint)
                }
                Text("Basis: \(Fmt.number(consumption, digits: 1)) l/100 km aus den Daten von \(car.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Card(title: "Verbrauch", symbol: "fuelpump") {
                Text("Trage in der Garage den Verbrauch deines Autos ein, um Liter, Kosten und CO₂ pro Fahrt zu sehen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var weather: some View {
        let condition = WeatherCondition(code: drive.weatherCode ?? 0, isDay: true)
        return Card(title: "Wetter beim Start", symbol: condition.symbol) {
            HStack {
                Text(condition.text)
                Spacer()
                if let t = drive.temperature {
                    Text("\(Fmt.number(t, digits: 0)) °C")
                        .font(.title3.bold())
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                drive.isFavorite.toggle()
                try? context.save()
            } label: {
                Label("Favorit", systemImage: drive.isFavorite ? "star.fill" : "star")
            }
            Menu {
                Button {
                    newTitle = drive.title.isEmpty ? drive.displayTitle : drive.title
                    showRename = true
                } label: {
                    Label("Umbenennen", systemImage: "pencil")
                }
                if cars.count > 1 {
                    Picker(selection: carSelection) {
                        ForEach(cars) { option in
                            Text(option.displayName).tag(Optional(option.id))
                        }
                    } label: {
                        Label("Auto ändern", systemImage: "car.2")
                    }
                    .pickerStyle(.menu)
                }
                if let gpxURL {
                    ShareLink(item: gpxURL) {
                        Label("Als GPX teilen", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    showDelete = true
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            } label: {
                Label("Mehr", systemImage: "ellipsis")
            }
        }
    }

    private func deleteDrive() {
        let target = drive
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            MapSnapshotCache.shared.remove(id: target.id)
            context.delete(target)
            try? context.save()
        }
    }
}
