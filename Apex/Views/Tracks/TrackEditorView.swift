import SwiftUI
import SwiftData
import MapKit

/// Create or edit a track: name, type and the start/finish line set by
/// tapping both edges on the map.
struct TrackEditorView: View {
    let track: Track?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name: String
    @State private var kind: TrackKind
    @State private var points: [CLLocationCoordinate2D]
    @State private var position: MapCameraPosition
    @State private var searchText = ""
    @State private var satellite = true
    @State private var searchFailed = false

    init(track: Track?) {
        self.track = track
        _name = State(initialValue: track?.name ?? "")
        _kind = State(initialValue: track?.kind ?? .circuit)
        var initial: [CLLocationCoordinate2D] = []
        if let track {
            initial = [track.startA.clCoordinate, track.startB.clCoordinate]
            if track.kind == .sprint, let a = track.finishA, let b = track.finishB {
                initial += [a.clCoordinate, b.clCoordinate]
            }
            _position = State(initialValue: .camera(MapCamera(centerCoordinate: track.center, distance: 900)))
        } else {
            _position = State(initialValue: .userLocation(fallback: .automatic))
        }
        _points = State(initialValue: initial)
    }

    private var requiredPoints: Int { kind == .circuit ? 2 : 4 }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && points.count >= requiredPoints
    }

    private var lineLength: Int {
        guard points.count >= 2 else { return 0 }
        return Int(Geo.distance(points[0], points[1]).rounded())
    }

    private var instruction: String {
        switch points.count {
        case 0:
            return kind == .circuit
                ? "Tippe auf einen Rand der Start/Ziel-Linie."
                : "Tippe auf einen Rand der Startlinie."
        case 1:
            return "Jetzt den anderen Rand antippen."
        case 2 where kind == .sprint:
            return "Ziellinie: ersten Rand antippen."
        case 3 where kind == .sprint:
            return "Ziellinie: anderen Rand antippen."
        default:
            return "Linie gesetzt · \(lineLength) m breit"
        }
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) {
                    UserAnnotation()
                    if points.count >= 2 {
                        MapPolyline(coordinates: [points[0], points[1]])
                            .stroke(.black, lineWidth: 8)
                        MapPolyline(coordinates: [points[0], points[1]])
                            .stroke(.white, style: StrokeStyle(lineWidth: 6, dash: [6, 6]))
                    }
                    if points.count >= 4 {
                        MapPolyline(coordinates: [points[2], points[3]])
                            .stroke(.red, style: StrokeStyle(lineWidth: 6, dash: [6, 6]))
                    }
                    ForEach(Array(points.enumerated()), id: \.offset) { index, coordinate in
                        Annotation("", coordinate: coordinate) {
                            Circle()
                                .fill(index < 2 ? Color.white : Color.red)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(.black, lineWidth: 2))
                        }
                    }
                }
                .mapStyle(satellite ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .onTapGesture { screenPoint in
                    guard points.count < requiredPoints,
                          let coordinate = proxy.convert(screenPoint, from: .local) else { return }
                    withAnimation(.snappy) { points.append(coordinate) }
                }
            }
            .safeAreaInset(edge: .top) { header }
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle(track == nil ? "Neue Strecke" : "Strecke bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .disabled(!isValid)
                }
            }
            .onChange(of: kind) { _, newKind in
                if newKind == .circuit && points.count > 2 {
                    points = Array(points.prefix(2))
                }
            }
        }
    }

    private var header: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                TextField("Name der Strecke", text: $name)
                    .font(.headline)
                    .padding(12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Ort oder Rennstrecke suchen", text: $searchText)
                        .submitLabel(.search)
                        .onSubmit { search() }
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                Picker("Typ", selection: $kind) {
                    ForEach(TrackKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text(searchFailed ? "Nichts gefunden." : instruction)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                Button {
                    withAnimation { _ = points.popLast() }
                } label: {
                    Label("Rückgängig", systemImage: "arrow.uturn.backward")
                }
                .disabled(points.isEmpty)
                Button {
                    withAnimation { points.removeAll() }
                } label: {
                    Label("Neu setzen", systemImage: "trash")
                }
                .disabled(points.isEmpty)
                Spacer()
                Button {
                    satellite.toggle()
                } label: {
                    Label(satellite ? "Karte" : "Satellit", systemImage: satellite ? "map" : "globe.europe.africa.fill")
                }
            }
            .buttonStyle(.glass)
            .lineLimit(1)
            .font(.subheadline)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        Task {
            do {
                let response = try await MKLocalSearch(request: request).start()
                searchFailed = response.mapItems.isEmpty
                if !response.mapItems.isEmpty {
                    withAnimation { position = .region(response.boundingRegion) }
                }
            } catch {
                searchFailed = true
            }
        }
    }

    private func save() {
        guard isValid else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let startA = Coordinate(points[0])
        let startB = Coordinate(points[1])
        let finishA = kind == .sprint ? Coordinate(points[2]) : nil
        let finishB = kind == .sprint ? Coordinate(points[3]) : nil
        if let track {
            track.name = trimmed
            track.kind = kind
            track.startA = startA
            track.startB = startB
            track.finishA = finishA
            track.finishB = finishB
            MapSnapshotCache.shared.remove(id: track.id)
        } else {
            let newTrack = Track(name: trimmed, kind: kind, startA: startA, startB: startB, finishA: finishA, finishB: finishB)
            context.insert(newTrack)
        }
        try? context.save()
        dismiss()
    }
}
