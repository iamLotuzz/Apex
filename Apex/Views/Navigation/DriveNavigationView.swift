import SwiftUI
import MapKit

/// Full-screen turn-by-turn view in the style of Apple Maps.
///
/// The camera follows the car tilted from behind. Before a turn it zooms in
/// close and steepens the pitch, so the lane markings of Apple's detailed
/// maps are visible; after the turn it zooms back out.
struct DriveNavigationView: View {
    @State private var position: MapCameraPosition = .automatic
    @State private var following = true
    @State private var showEndDialog = false
    private var nav: NavigationService { .shared }

    var body: some View {
        ZStack {
            map
            VStack(spacing: 10) {
                maneuverCard
                if let saving = nav.fasterRoute.map({ _ in nav.fasterRouteSaving }) {
                    fasterRouteBanner(saving: saving)
                }
                Spacer()
                HStack {
                    Spacer()
                    if !following {
                        Button {
                            following = true
                            updateCamera(animated: true)
                        } label: {
                            Image(systemName: "location.north.line.fill")
                                .font(.title3)
                                .frame(width: 50, height: 50)
                        }
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Wieder zentrieren")
                    }
                }
                bottomCard
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onChange(of: nav.updateCount) { _, _ in
            if following { updateCamera(animated: true) }
        }
        .onAppear { updateCamera(animated: false) }
        .confirmationDialog("Navigation beenden?", isPresented: $showEndDialog, titleVisibility: .visible) {
            Button("Beenden", role: .destructive) { nav.stop() }
        }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $position) {
            if nav.routeCoordinates.count >= 2 {
                MapPolyline(coordinates: nav.routeCoordinates)
                    .stroke(Color(red: 0.0, green: 0.30, blue: 0.75), style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: nav.routeCoordinates)
                    .stroke(Color(red: 0.16, green: 0.53, blue: 1.0), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
            }
            if let destination = nav.destinationCoordinate {
                Marker(nav.destinationName, systemImage: "flag.checkered", coordinate: destination)
                    .tint(.red)
            }
            if let car = nav.snappedCoordinate ?? nav.location?.coordinate {
                Annotation("", coordinate: car) {
                    NavigationPuck()
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .automatic, pointsOfInterest: .excludingAll, showsTraffic: true))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .ignoresSafeArea()
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in following = false })
    }

    /// Normal: 650 m behind and above (1.3 km on fast roads), pitch 50°.
    /// Approaching a maneuver: 170 m, pitch 62° – close enough for lanes.
    private func updateCamera(animated: Bool) {
        guard let car = nav.snappedCoordinate ?? nav.location?.coordinate else { return }
        let speed = max(0, nav.location?.speed ?? 0)
        let approaching = !nav.arrived && nav.distanceToManeuver < max(250, speed * 15)
        let distance: Double = approaching ? 170 : (speed > 25 ? 1300 : 650)
        let pitch: Double = approaching ? 62 : 50
        // Look a bit ahead so the car sits in the lower part of the screen.
        let ahead = Self.offset(car, heading: nav.heading, meters: distance * (approaching ? 0.18 : 0.28))
        let camera = MapCamera(centerCoordinate: ahead, distance: distance, heading: nav.heading, pitch: pitch)
        if animated {
            withAnimation(.easeInOut(duration: approaching ? 1.2 : 0.9)) {
                position = .camera(camera)
            }
        } else {
            position = .camera(camera)
        }
    }

    private static func offset(_ c: CLLocationCoordinate2D, heading: Double, meters: Double) -> CLLocationCoordinate2D {
        let radians = heading * .pi / 180
        let north = cos(radians) * meters
        let east = sin(radians) * meters
        return CLLocationCoordinate2D(
            latitude: c.latitude + north / 111_320,
            longitude: c.longitude + east / (111_320 * cos(c.latitude * .pi / 180))
        )
    }

    // MARK: Cards

    @ViewBuilder
    private var maneuverCard: some View {
        if nav.arrived {
            HStack(spacing: 14) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 44, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Angekommen")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(nav.destinationName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer()
            }
            .modifier(ManeuverCardStyle())
        } else if let route = nav.route, route.steps.indices.contains(nav.stepIndex) {
            let step = route.steps[nav.stepIndex]
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Image(systemName: ManeuverSymbol.name(for: step.instructions))
                        .font(.system(size: 46, weight: .bold))
                        .frame(width: 62)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nav.isRerouting ? "Neue Route …" : NavigationService.displayDistance(nav.distanceToManeuver))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(step.instructions.isEmpty ? "Der Route folgen" : step.instructions)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                    }
                    Spacer(minLength: 0)
                }
                if route.steps.indices.contains(nav.stepIndex + 1), nav.distanceToManeuver < 600 {
                    let then = route.steps[nav.stepIndex + 1]
                    if then.distance < 300, !then.instructions.isEmpty {
                        HStack(spacing: 8) {
                            Text("Dann")
                                .font(.subheadline.weight(.semibold))
                            Image(systemName: ManeuverSymbol.name(for: then.instructions))
                                .font(.subheadline.weight(.bold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.15), in: .capsule)
                    }
                }
            }
            .modifier(ManeuverCardStyle())
        }
    }

    private func fasterRouteBanner(saving: TimeInterval) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Schnellere Route")
                    .font(.headline)
                Text("\(Int((saving / 60).rounded())) Min. schneller")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Nein") { nav.dismissFasterRoute() }
                .buttonStyle(.bordered)
            Button("Übernehmen") { nav.acceptFasterRoute() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var bottomCard: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text("\(Int((max(0, nav.location?.speed ?? 0) * 3.6).rounded()))")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("km/h")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 58, height: 58)
            .background(.background, in: .circle)

            VStack(spacing: 2) {
                Text(Date().addingTimeInterval(nav.remainingTime).formatted(date: .omitted, time: .shortened))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text("Ankunft · \(Fmt.duration(nav.remainingTime)) · \(NavigationService.displayDistance(nav.remainingDistance))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)

            Button {
                if nav.arrived { nav.stop() } else { showEndDialog = true }
            } label: {
                Text(nav.arrived ? "Fertig" : "Beenden")
                    .font(.headline)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(nav.arrived ? .blue : .red)
            .controlSize(.large)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }
}

/// Dark glass banner with white text, like the maneuver card in Apple Maps.
private struct ManeuverCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Color.black.opacity(0.6)), in: .rect(cornerRadius: 30))
    }
}

/// The car position: a blue arrow in a white disc, always pointing up
/// because the camera turns with the route.
struct NavigationPuck: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            Image(systemName: "location.north.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(red: 0.16, green: 0.53, blue: 1.0))
        }
    }
}
