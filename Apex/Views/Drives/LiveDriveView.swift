import SwiftUI
import MapKit

/// Map that follows the user while a drive records.
struct LiveDriveView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    private var location: LocationService { .shared }
    private var car: Car? { Persistence.activeCar() }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: $position) {
                    UserAnnotation()
                    if location.livePoints.count >= 2 {
                        MapPolyline(coordinates: location.livePoints.map(\.coordinate))
                            .stroke(.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .ignoresSafeArea(edges: .bottom)

                panel
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
            .navigationTitle(location.isRecording ? "Fahrt läuft" : "Keine aktive Fahrt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    header
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    /// Title with a pulsing dot and "seit 17:42:08" underneath.
    private var header: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                if location.isRecording {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                }
                Text(location.isRecording ? "Fahrt läuft" : "Keine aktive Fahrt")
                    .font(.headline)
            }
            if location.isRecording, let start = location.driveStart {
                Text("seit \(start.formatted(date: .omitted, time: .standard)) · ab der Abfahrt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var panel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 16) {
                HStack(alignment: .center, spacing: 10) {
                    PixelImage(image: car?.frontImage ?? DefaultPixelCar.frontImage)
                        .frame(width: 44, height: 26)
                    Text(car?.displayName ?? "Mein Auto")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if location.isRecording {
                        LivePill(showsDuration: false)
                    }
                }

                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(Fmt.kmhValue(location.speed))
                        .font(.system(size: 72, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("km/h")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 0) {
                    MiniStat(value: Fmt.distance(location.liveDistance), caption: "Strecke")
                    MiniStat(value: Fmt.clock(location.liveDuration), caption: "Dauer")
                    MiniStat(value: Fmt.kmh(location.liveMaxSpeed), caption: "Max.")
                }
                .padding(.vertical, 10)
                .background(.fill.tertiary, in: .rect(cornerRadius: 16))

                if location.isRecording {
                    Button(role: .destructive) {
                        location.stopDrive()
                        dismiss()
                    } label: {
                        Label("Fahrt beenden & speichern", systemImage: "stop.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                } else {
                    Button {
                        location.startManualDrive()
                    } label: {
                        Label("Fahrt starten", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
        }
    }
}

struct LabeledValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
