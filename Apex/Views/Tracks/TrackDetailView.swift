import SwiftUI
import SwiftData
import MapKit

struct TrackDetailView: View {
    let track: Track

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var sessions: [TrackSession]
    @Query(sort: \Car.createdAt) private var cars: [Car]
    @AppStorage(SharedStore.Key.lapReference, store: SharedStore.defaults) private var referenceRaw = LapReference.previous.rawValue

    @State private var showLive = false
    @State private var showEditor = false
    @State private var showDelete = false
    @State private var finishedSession: SessionLink?

    init(track: Track) {
        self.track = track
        let id = track.id
        _sessions = Query(filter: #Predicate<TrackSession> { $0.trackID == id }, sort: \TrackSession.date, order: .reverse)
    }

    private var reference: LapReference { LapReference(rawValue: referenceRaw) ?? .previous }

    private var bestSession: TrackSession? {
        sessions.filter { $0.bestLapTime != nil }.min { ($0.bestLapTime ?? .infinity) < ($1.bestLapTime ?? .infinity) }
    }

    /// Fastest lap ever driven here; the first lap of a new session is
    /// compared with it. Decoded once per best session, not on every redraw.
    @State private var storedBestLap: Lap?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                TrackMap(track: track, lap: storedBestLap)
                    .frame(height: 280)
                    .clipShape(.rect(cornerRadius: 28))

                StatGrid {
                    StatTile(title: "Bestzeit", value: track.bestLapTime.map { Fmt.lap($0) } ?? "–", symbol: "trophy.fill", tint: .purple)
                    StatTile(title: "Sessions", value: "\(sessions.count)", symbol: "stopwatch", tint: .orange)
                    StatTile(title: "Runden", value: "\(sessions.reduce(0) { $0 + $1.lapCount })", symbol: "arrow.triangle.2.circlepath", tint: .blue)
                    StatTile(title: "Länge", value: track.lapLength.map { Fmt.km($0, digits: 2) } ?? "–", unit: track.lapLength == nil ? "" : "km", symbol: "ruler", tint: .teal)
                    StatTile(title: "Höchsttempo", value: Fmt.kmhValue(sessions.map(\.maxSpeed).max() ?? 0), unit: "km/h", symbol: "bolt.fill", tint: .red)
                    StatTile(title: "Typ", value: track.kind == .circuit ? "Rundkurs" : "Sprint", symbol: "flag.checkered", tint: .gray)
                }

                Card(title: "Delta-Referenz", symbol: "plusminus") {
                    Picker("Referenz", selection: $referenceRaw) {
                        ForEach(LapReference.allCases) { ref in
                            Text(ref.title).tag(ref.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Das große Delta im Querformat vergleicht deine aktuelle Runde mit dieser Referenz.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Card(title: "Sessions", symbol: "list.bullet") {
                    if sessions.isEmpty {
                        Text("Noch keine Session. Starte unten, fahr über die Start/Ziel-Linie – die Zeitmessung beginnt automatisch.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(sessions) { session in
                                NavigationLink(value: SessionLink(id: session.id)) {
                                    SessionRow(
                                        session: session,
                                        isBest: session.id == bestSession?.id,
                                        car: cars.count > 1 ? cars.first(where: { $0.id == session.carID }) : nil
                                    )
                                }
                                .buttonStyle(.plain)
                                if session.id != sessions.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 100)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                showLive = true
            } label: {
                Label("Session starten", systemImage: "flag.checkered")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationTitle(track.name)
        .navigationBarTitleDisplayMode(.large)
        .task(id: "\(bestSession?.id.uuidString ?? "-")/\(bestSession?.bestLapTime ?? 0)") {
            storedBestLap = bestSession?.laps.min { $0.duration < $1.duration }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showEditor = true
                    } label: {
                        Label("Bearbeiten", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDelete = true
                    } label: {
                        Label("Strecke löschen", systemImage: "trash")
                    }
                } label: {
                    Label("Mehr", systemImage: "ellipsis")
                }
            }
        }
        .navigationDestination(for: SessionLink.self) { link in
            if let session = sessions.first(where: { $0.id == link.id }) {
                SessionDetailView(session: session)
            }
        }
        .navigationDestination(item: $finishedSession) { link in
            if let session = sessions.first(where: { $0.id == link.id }) {
                SessionDetailView(session: session)
            }
        }
        .sheet(isPresented: $showEditor) {
            TrackEditorView(track: track)
        }
        .fullScreenCover(isPresented: $showLive) {
            LiveSessionView(track: track, reference: reference, storedReference: storedBestLap) { sessionID in
                if let sessionID {
                    finishedSession = SessionLink(id: sessionID)
                }
            }
        }
        .confirmationDialog("Strecke löschen?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Strecke und Sessions löschen", role: .destructive) { deleteTrack() }
        }
    }

    private func deleteTrack() {
        let target = track
        let targetSessions = sessions
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            for session in targetSessions { context.delete(session) }
            MapSnapshotCache.shared.remove(id: target.id)
            context.delete(target)
            try? context.save()
        }
    }
}

struct SessionRow: View {
    let session: TrackSession
    var isBest = false
    var car: Car? = nil

    var body: some View {
        HStack {
            if let car {
                PixelImage(image: car.frontImage)
                    .frame(width: 34, height: 20)
                    .accessibilityLabel(car.displayName)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .font(.subheadline.weight(.semibold))
                Text("\(session.lapCount) Runden · max. \(Fmt.kmh(session.maxSpeed))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let best = session.bestLapTime {
                HStack(spacing: 4) {
                    if isBest {
                        Image(systemName: "trophy.fill")
                            .foregroundStyle(.purple)
                    }
                    Text(Fmt.lap(best))
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}

/// Map of a track with its start/finish line and an optional lap trace.
struct TrackMap: View {
    let track: Track
    var lap: Lap?

    @State private var position: MapCameraPosition
    @State private var segments: [SpeedSegment] = []

    init(track: Track, lap: Lap?) {
        self.track = track
        self.lap = lap
        var coordinates = [track.startA.clCoordinate, track.startB.clCoordinate]
        if let lap { coordinates += lap.points.map(\.coordinate) }
        let rect = MapSnapshotCache.mapRect(for: coordinates, padding: 0.1)
        _position = State(initialValue: .rect(rect))
    }

    var body: some View {
        Map(position: $position) {
            ForEach(segments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            MapPolyline(coordinates: [track.startA.clCoordinate, track.startB.clCoordinate])
                .stroke(.white, style: StrokeStyle(lineWidth: 6, dash: [5, 5]))
            if let a = track.finishA, let b = track.finishB, track.kind == .sprint {
                MapPolyline(coordinates: [a.clCoordinate, b.clCoordinate])
                    .stroke(.red, style: StrokeStyle(lineWidth: 6, dash: [5, 5]))
            }
            UserAnnotation()
        }
        .mapStyle(.hybrid(elevation: .realistic))
        // Colour segments are built once per lap, not on every redraw.
        .task(id: lap?.duration) {
            segments = lap.map { RouteBuilder.segments($0.points) } ?? []
        }
    }
}
