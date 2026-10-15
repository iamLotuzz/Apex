import SwiftUI
import SwiftData
import MapKit
import UIKit

/// "Strecke abfahren": tap Start on the start/finish line, drive the lap,
/// tap Stop – the track and its first lap are created from the GPS trace.
struct TrackRecorderView: View {
    var onSaved: (Track) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var recorder: TrackRecorder
    @State private var position: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var name = ""

    init(onSaved: @escaping (Track) -> Void = { _ in }) {
        self.onSaved = onSaved
        _recorder = State(initialValue: TrackRecorder())
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                panel
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
            .navigationTitle("Strecke abfahren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .onAppear(perform: begin)
            .onDisappear(perform: end)
            .onChange(of: recorder.phase) { _, phase in
                if phase == .finished, let trace = recorder.result?.trace, trace.count >= 2 {
                    withAnimation { position = .rect(MapSnapshotCache.mapRect(for: trace, padding: 0.2)) }
                } else if phase == .ready {
                    position = .userLocation(followsHeading: true, fallback: .automatic)
                }
            }
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $position) {
            UserAnnotation()
            if recorder.trace.count >= 2 {
                MapPolyline(coordinates: recorder.trace)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let result = recorder.result {
                MapPolyline(coordinates: [result.startA, result.startB])
                    .stroke(.black, lineWidth: 8)
                MapPolyline(coordinates: [result.startA, result.startB])
                    .stroke(.white, style: StrokeStyle(lineWidth: 6, dash: [5, 5]))
                if let a = result.finishA, let b = result.finishB {
                    MapPolyline(coordinates: [a, b])
                        .stroke(.red, style: StrokeStyle(lineWidth: 6, dash: [5, 5]))
                }
            } else if let start = recorder.startPoint {
                Annotation("Start/Ziel", coordinate: start) {
                    Image(systemName: "flag.checkered")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black, in: .circle)
                }
            }
        }
        .mapStyle(.hybrid(elevation: .realistic))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Panel

    @ViewBuilder
    private var panel: some View {
        switch recorder.phase {
        case .ready:
            readyPanel
        case .recording:
            recordingPanel
        case .finished:
            finishedPanel
        }
    }

    private var readyPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("An der Start/Ziel-Linie auf Start tippen", systemImage: "flag.checkered")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 0) {
                MiniStat(value: Fmt.kmhValue(recorder.speed), caption: "km/h")
                MiniStat(value: recorder.accuracy < 0 ? "–" : "±\(Int(recorder.accuracy)) m", caption: recorder.gpsReady ? "GPS bereit" : "GPS sucht …")
            }
            Button {
                recorder.start()
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
            .disabled(!recorder.gpsReady)
            Text("Tipp: im Fahrtempo über die Linie starten")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }

    private var recordingPanel: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            VStack(spacing: 14) {
                HStack {
                    Label(recorder.lapClosed ? "Runde geschlossen" : "Aufnahme läuft", systemImage: recorder.lapClosed ? "checkmark.circle.fill" : "record.circle")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(recorder.lapClosed ? Color.green : Color.red)
                        .symbolEffect(.pulse, isActive: !recorder.lapClosed)
                    Spacer()
                }
                Text(Fmt.lap(recorder.elapsed, digits: 1))
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    MiniStat(value: Fmt.distance(recorder.distance), caption: "gefahren")
                    MiniStat(value: Fmt.kmhValue(recorder.speed), caption: "km/h")
                    MiniStat(value: toStartText, caption: "bis Start/Ziel")
                }
                Button {
                    recorder.stop()
                } label: {
                    Label("Stopp", systemImage: "stop.fill")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                Text(recorder.lapClosed ? "Runde geschlossen – jetzt Stopp tippen" : "Stopp an der Linie – oder am Ziel (A → B)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
        }
    }

    private var toStartText: String {
        guard let d = recorder.distanceToStart, recorder.distance > 60 else { return "–" }
        return Fmt.distance(d)
    }

    @ViewBuilder
    private var finishedPanel: some View {
        if let result = recorder.result {
            VStack(alignment: .leading, spacing: 14) {
                Label(result.kind == .circuit ? "Rundkurs erkannt" : "Sprint A → B erkannt",
                      systemImage: result.kind == .circuit ? "arrow.triangle.2.circlepath" : "arrow.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let lap = result.lap {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.lap(lap.duration))
                            .font(.system(size: 48, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text("\(Fmt.distance(lap.distance)) · max. \(Fmt.kmh(lap.maxSpeed)) · Runde 1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                TextField("Name der Strecke", text: $name)
                    .font(.headline)
                    .padding(12)
                    .background(.background.secondary, in: .rect(cornerRadius: 14))
                HStack(spacing: 10) {
                    Button {
                        recorder.reset()
                    } label: {
                        Label("Nochmal", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    Button {
                        save()
                    } label: {
                        Label("Sichern", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Linie später unter „Bearbeiten“ verschiebbar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
        } else {
            VStack(spacing: 12) {
                Label("Zu kurz aufgezeichnet", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Erst ein paar Meter fahren, dann Stopp")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Button("Nochmal") { recorder.reset() }
                    .buttonStyle(.glassProminent)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
        }
    }

    // MARK: Flow

    private func begin() {
        UIApplication.shared.isIdleTimerDisabled = true
        let recorder = self.recorder
        LocationService.shared.beginSession { location in
            recorder.process(location)
        }
    }

    private func end() {
        LocationService.shared.endSession()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let track = recorder.save(name: trimmed, in: context) else { return }
        dismiss()
        onSaved(track)
    }
}
