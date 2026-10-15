import SwiftUI
import MapKit

/// Map that follows the user while a drive records, with a Maps-style
/// card at the bottom.
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
                            .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .ignoresSafeArea(edges: .bottom)

                card
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .navigationTitle(location.isRecording ? "Fahrt läuft" : "Keine aktive Fahrt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if location.isRecording {
                    ToolbarItem(placement: .topBarLeading) {
                        LivePill()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private var card: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    PixelImage(image: car?.frontImage ?? DefaultPixelCar.frontImage)
                        .frame(width: 40, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(car?.displayName ?? "Mein Auto")
                            .font(.headline)
                        if location.isRecording, let start = location.driveStart {
                            Text("Unterwegs seit \(Fmt.time(start))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    GridRow {
                        metric("Tempo", Fmt.kmhValue(location.speed), unit: "km/h", large: true)
                            .gridCellColumns(3)
                    }
                    GridRow {
                        metric("Strecke", Fmt.km(location.liveDistance, digits: 1), unit: "km")
                        metric("Dauer", Fmt.clock(location.liveDuration), unit: nil)
                        metric("Max.", Fmt.kmhValue(location.liveMaxSpeed), unit: "km/h")
                    }
                }

                if location.isRecording {
                    Button(role: .destructive) {
                        location.stopDrive()
                        dismiss()
                    } label: {
                        Text("Fahrt beenden")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                } else {
                    Button {
                        location.startManualDrive()
                    } label: {
                        Text("Fahrt starten")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 34))
        }
    }

    /// A Fitness-style metric: grey caption, rounded number, small unit.
    private func metric(_ title: String, _ value: String, unit: String?, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: large ? 54 : 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(large ? .title3.weight(.medium) : .subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
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
