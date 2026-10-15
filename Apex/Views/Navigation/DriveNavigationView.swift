import SwiftUI
import MapKit

/// Full-screen turn-by-turn view in the style of Apple Maps, portrait and
/// landscape.
///
/// The camera follows the car tilted from behind and moves in one-second
/// linear steps that match the GPS rate, so the marker glides. Before a
/// turn it zooms in close and steepens, so lane markings of Apple's detailed
/// maps are visible.
struct DriveNavigationView: View {
    @State private var position: MapCameraPosition = .automatic
    @State private var following = true
    @State private var showEndDialog = false
    @State private var showSound = false
    @AppStorage(NavSettings.puckStyle, store: SharedStore.defaults) private var puckStyle = "arrow"
    @AppStorage(NavSettings.directionsOn, store: SharedStore.defaults) private var directionsOn = true
    @AppStorage(NavSettings.rallyOn, store: SharedStore.defaults) private var rallyOn = true
    private var nav: NavigationService { .shared }
    private var limits: SpeedLimitService { .shared }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                map
                if landscape {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 10) {
                            maneuverCard
                            rallyChip
                            fasterRouteBanner
                            Spacer(minLength: 0)
                            HStack(alignment: .bottom) {
                                speedCluster
                                Spacer()
                            }
                            bottomBar
                        }
                        .frame(width: min(360, geo.size.width * 0.42))
                        Spacer()
                        controls
                    }
                    .padding(12)
                } else {
                    VStack(spacing: 10) {
                        maneuverCard
                        HStack(alignment: .top) {
                            rallyChip
                            Spacer()
                            controls
                        }
                        fasterRouteBanner
                        Spacer()
                        HStack(alignment: .bottom) {
                            speedCluster
                            Spacer()
                        }
                        bottomBar
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .onChange(of: nav.updateCount) { _, _ in
            if following { updateCamera(animated: true) }
        }
        .onAppear {
            OrientationController.lock(.allButUpsideDown)
            updateCamera(animated: false)
        }
        .onDisappear {
            OrientationController.lock(.portrait)
        }
        .sheet(isPresented: $showSound) {
            NavigationSoundSheet()
                .presentationDetents([.height(440)])
        }
        .confirmationDialog("Navigation beenden?", isPresented: $showEndDialog, titleVisibility: .visible) {
            Button("Beenden", role: .destructive) { nav.stop() }
        } message: {
            Text("Die Fahrt wird gespeichert.")
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
            if let car = nav.displayCoordinate {
                Annotation("", coordinate: car) {
                    NavigationPuck(style: puckStyle)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .automatic, pointsOfInterest: .excludingAll, showsTraffic: true))
        .mapControls {
            MapCompass()
        }
        .ignoresSafeArea()
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in following = false })
    }

    /// Normal: 650 m (1.3 km on fast roads), pitch 50°.
    /// Approaching a maneuver: 170 m, pitch 62° – close enough for lanes.
    private func updateCamera(animated: Bool) {
        guard let car = nav.displayCoordinate else { return }
        let approaching = !nav.arrived && nav.distanceToManeuver < max(250, nav.speed * 15)
        let distance: Double = approaching ? 170 : (nav.speed > 25 ? 1300 : 650)
        let pitch: Double = approaching ? 62 : 50
        let ahead = Self.offset(car, heading: nav.heading, meters: distance * (approaching ? 0.18 : 0.28))
        let camera = MapCamera(centerCoordinate: ahead, distance: distance, heading: nav.heading, pitch: pitch)
        if animated {
            withAnimation(.linear(duration: 1.0)) {
                position = .camera(camera)
            }
        } else {
            position = .camera(camera)
        }
    }

    private static func offset(_ c: CLLocationCoordinate2D, heading: Double, meters: Double) -> CLLocationCoordinate2D {
        let radians = heading * .pi / 180
        return CLLocationCoordinate2D(
            latitude: c.latitude + cos(radians) * meters / 111_320,
            longitude: c.longitude + sin(radians) * meters / (111_320 * cos(c.latitude * .pi / 180))
        )
    }

    // MARK: Cards

    @ViewBuilder
    private var maneuverCard: some View {
        if nav.arrived {
            HStack(spacing: 14) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 38, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Angekommen")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(nav.destinationName)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .modifier(ManeuverCardStyle())
        } else if let route = nav.route, route.steps.indices.contains(nav.stepIndex) {
            let step = route.steps[nav.stepIndex]
            HStack(spacing: 14) {
                Image(systemName: ManeuverSymbol.name(for: step.instructions))
                    .font(.system(size: 40, weight: .bold))
                    .frame(width: 50)
                VStack(alignment: .leading, spacing: 1) {
                    Text(nav.isRerouting ? "Neue Route …" : NavigationService.displayDistance(nav.distanceToManeuver))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(step.instructions.isEmpty ? "Der Route folgen" : step.instructions)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
                if route.steps.indices.contains(nav.stepIndex + 1), nav.distanceToManeuver < 600 {
                    let then = route.steps[nav.stepIndex + 1]
                    if then.distance < 300, !then.instructions.isEmpty {
                        VStack(spacing: 2) {
                            Text("Dann")
                                .font(.caption2.weight(.semibold))
                            Image(systemName: ManeuverSymbol.name(for: then.instructions))
                                .font(.headline)
                        }
                        .frame(width: 44, height: 50)
                        .background(.white.opacity(0.14), in: .rect(cornerRadius: 12))
                    }
                }
            }
            .modifier(ManeuverCardStyle())
        }
    }

    @ViewBuilder
    private var rallyChip: some View {
        if rallyOn, let note = nav.nextRallyNote, nav.distanceToRallyNote < 400, !nav.arrived {
            HStack(spacing: 8) {
                Image(systemName: note.symbol)
                    .font(.headline)
                Text(note.spoken)
                    .font(.headline)
                Text(NavigationService.displayDistance(nav.distanceToRallyNote))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular.tint(Color.orange.opacity(0.55)), in: .capsule)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var fasterRouteBanner: some View {
        if nav.fasterRoute != nil {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.green)
                Text("\(Int((nav.fasterRouteSaving / 60).rounded())) Min. schneller")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Nein") { nav.dismissFasterRoute() }
                    .buttonStyle(.bordered)
                Button("Übernehmen") { nav.acceptFasterRoute() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }

    /// Current speed with the speed-limit sign next to it, like Apple Maps.
    private var speedCluster: some View {
        let kmh = Int((nav.speed * 3.6).rounded())
        let limit = limits.limit
        let over = (limit ?? 0) > 0 && kmh > (limit ?? 0) + 3
        return HStack(spacing: -8) {
            VStack(spacing: -2) {
                Text("\(kmh)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(over ? Color.red : Color.primary)
                    .contentTransition(.numericText())
                Text("km/h")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 62, height: 62)
            .glassEffect(.regular, in: .circle)
            .zIndex(1)

            if let limit {
                SpeedLimitSign(limit: limit)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                Button {
                    showSound = true
                } label: {
                    Image(systemName: directionsOn || rallyOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Ton und Ansagen")

                Button {
                    nav.toggleMedia()
                } label: {
                    Image(systemName: nav.mediaPaused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(nav.mediaPaused ? "Musik oder Hörbuch fortsetzen" : "Musik oder Hörbuch pausieren")

                if !following {
                    Button {
                        following = true
                        updateCamera(animated: true)
                    } label: {
                        Image(systemName: "location.north.line.fill")
                            .font(.title3)
                            .frame(width: 48, height: 48)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Wieder zentrieren")
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Date().addingTimeInterval(nav.remainingTime).formatted(date: .omitted, time: .shortened))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                Text("\(Fmt.duration(nav.remainingTime)) · \(NavigationService.displayDistance(nav.remainingDistance))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                if nav.arrived { nav.stop() } else { showEndDialog = true }
            } label: {
                Text(nav.arrived ? "Fertig" : "Beenden")
                    .font(.headline)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(nav.arrived ? .blue : .red)
            .controlSize(.large)
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Dark glass banner with white text, like the maneuver card in Apple Maps.
private struct ManeuverCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Color.black.opacity(0.62)), in: .rect(cornerRadius: 28))
    }
}

/// German speed-limit sign: white disc, red ring, black number.
struct SpeedLimitSign: View {
    let limit: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
            if limit == 0 {
                // End of all limits: white sign with a black diagonal.
                Circle()
                    .stroke(Color.gray.opacity(0.5), lineWidth: 2)
                Rectangle()
                    .fill(.black)
                    .frame(width: 4, height: 54)
                    .rotationEffect(.degrees(45))
            } else {
                Circle()
                    .strokeBorder(Color(red: 0.86, green: 0.1, blue: 0.1), lineWidth: 6)
                Text("\(limit)")
                    .font(.system(size: limit >= 100 ? 18 : 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .monospacedDigit()
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(.circle)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .accessibilityLabel(limit == 0 ? "Kein Tempolimit" : "Tempolimit \(limit)")
    }
}

/// The car marker: a blue arrow or the user's pixel car.
struct NavigationPuck: View {
    var style: String

    var body: some View {
        if style == "car" {
            PixelImage(image: Persistence.activeCar()?.frontImage ?? DefaultPixelCar.frontImage)
                .frame(width: 58, height: 34)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
        } else {
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
}

/// Sound settings during navigation: directions and rally notes each with
/// on/off and volume, plus the car marker.
struct NavigationSoundSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NavSettings.directionsOn, store: SharedStore.defaults) private var directionsOn = true
    @AppStorage(NavSettings.directionsVolume, store: SharedStore.defaults) private var directionsVolume = 1.0
    @AppStorage(NavSettings.rallyOn, store: SharedStore.defaults) private var rallyOn = true
    @AppStorage(NavSettings.rallyVolume, store: SharedStore.defaults) private var rallyVolume = 0.85
    @AppStorage(NavSettings.puckStyle, store: SharedStore.defaults) private var puckStyle = "arrow"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Wegbeschreibung", isOn: $directionsOn)
                    if directionsOn {
                        volumeRow(value: $directionsVolume) { NavigationService.shared.testVoice(rally: false) }
                    }
                }
                Section {
                    Toggle("Rallye-Ansagen", isOn: $rallyOn)
                    if rallyOn {
                        volumeRow(value: $rallyVolume) { NavigationService.shared.testVoice(rally: true) }
                    }
                }
                Section("Markierung") {
                    Picker("Markierung", selection: $puckStyle) {
                        Text("Pfeil").tag("arrow")
                        Text("Pixel-Auto").tag("car")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Ton & Anzeige")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private func volumeRow(value: Binding<Double>, test: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
            Button {
                test()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Probe abspielen")
        }
    }
}
