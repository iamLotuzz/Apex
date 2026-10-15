import SwiftUI
import MapKit
import PhotosUI

/// Full-screen turn-by-turn view in the style of Apple Maps, portrait and
/// landscape.
///
/// The camera follows the car tilted from behind and is set on every screen
/// frame from the live pose, so marker, map and speed move continuously.
/// Before a turn it zooms in close and steepens, so lane markings of
/// Apple's detailed maps are visible.
struct DriveNavigationView: View {
    @State private var following = true
    @State private var showEndDialog = false
    @State private var showSound = false
    @Namespace private var mapScope
    @AppStorage(NavSettings.puckStyle, store: SharedStore.defaults) private var puckStyle = "arrow"
    @AppStorage(NavSettings.directionsOn, store: SharedStore.defaults) private var directionsOn = true
    @AppStorage(NavSettings.rallyOn, store: SharedStore.defaults) private var rallyOn = true
    private var nav: NavigationService { .shared }
    private var limits: SpeedLimitService { .shared }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                NavigationMapLayer(following: $following, puckStyle: puckStyle, scope: mapScope)
                if landscape {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 10) {
                            maneuverCard
                            rallyChip
                            fasterRouteBanner
                            trafficBanner
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
                        HStack(alignment: .top, spacing: 10) {
                            rallyChip
                            Spacer(minLength: 0)
                            controls
                        }
                        fasterRouteBanner
                        trafficBanner
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
        .mapScope(mapScope)
        .onAppear {
            OrientationController.lock(.allButUpsideDown)
        }
        .onDisappear {
            OrientationController.lock(.portrait)
        }
        .sheet(isPresented: $showSound) {
            NavigationSoundSheet()
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Navigation beenden?", isPresented: $showEndDialog, titleVisibility: .visible) {
            Button("Beenden", role: .destructive) { nav.stop() }
        } message: {
            Text("Die Fahrt wird gespeichert.")
        }
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
                    ManeuverDistanceText()
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
        if rallyOn, !nav.arrived {
            RallyChip()
                .layoutPriority(1)
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

    /// Delay, cleared traffic or slow traffic ahead, for ~10 s.
    @ViewBuilder
    private var trafficBanner: some View {
        if let notice = nav.trafficNotice {
            let (symbol, tint, title, detail): (String, Color, String, String) = {
                switch notice {
                case .delay(let minutes, let arrival):
                    return ("exclamationmark.triangle.fill", .red, "+\(minutes) Min. Verzögerung", "Ankunft \(arrival.formatted(date: .omitted, time: .shortened))")
                case .cleared(let minutes, let arrival):
                    return ("checkmark.circle.fill", .green, "\(minutes) Min. schneller", "Ankunft \(arrival.formatted(date: .omitted, time: .shortened))")
                case .slowTraffic:
                    return ("car.2.fill", .orange, "Stockender Verkehr", "Vorsichtig fahren")
                }
            }()
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var speedCluster: some View {
        LiveSpeedCluster()
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
                    // The compass sits in this column instead of the map's
                    // corner, so it never covers the cards.
                    MapCompass(scope: mapScope)
                        .mapControlVisibility(.visible)
                        .frame(width: 48, height: 48)
                    Button {
                        following = true
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
                // Red for two minutes after the arrival got later.
                Text(Date().addingTimeInterval(nav.remainingTime).formatted(date: .omitted, time: .shortened))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Date() < nav.arrivalLateUntil ? Color.red : Color.primary)
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

/// The map with route, destination and car. Kept in its own view so the
/// per-frame pose updates only redraw the map, speed and distance, not the
/// whole navigation screen.
private struct NavigationMapLayer: View {
    @Binding var following: Bool
    var puckStyle: String
    var scope: Namespace.ID
    @State private var position: MapCameraPosition = .automatic
    @State private var cameraHeading: Double = 0
    /// Loaded once and when the marker changes; the marker redraws per frame.
    @State private var markerImage: UIImage = DefaultPixelCar.frontImage
    @State private var zoom: Double = 650
    @State private var pitch: Double = 50
    @State private var lastFrame = Date()
    private var nav: NavigationService { .shared }

    var body: some View {
        Map(position: $position, scope: scope) {
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
            if let pose = nav.pose {
                Annotation("", coordinate: pose.coordinate, anchor: .center) {
                    NavigationPuck(style: puckStyle, rotation: pose.heading - cameraHeading, image: markerImage)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .automatic, pointsOfInterest: .excludingAll, showsTraffic: true))
        // No built-in controls: the compass would sit on top of the cards.
        // It lives in the control column instead (see DriveNavigationView).
        .mapControls {
            MapCompass()
        }
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .continuous) { context in
            cameraHeading = context.camera.heading
        }
        .ignoresSafeArea()
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in following = false })
        .onChange(of: nav.pose) { _, pose in
            if following, let pose { follow(pose) }
        }
        .onChange(of: following) { _, now in
            if now, let pose = nav.pose { follow(pose) }
        }
        .task { loadMarker() }
        .onReceive(NotificationCenter.default.publisher(for: NavigationPuck.markerChanged)) { _ in loadMarker() }
    }

    private func loadMarker() {
        markerImage = Persistence.activeCar()?.navImage ?? DefaultPixelCar.frontImage
    }

    /// Set on every frame, without animation: the pose itself is already
    /// smooth. Normal: 650 m (1.3 km on fast roads), pitch 50°. Approaching a
    /// maneuver: 170 m, pitch 62° – close enough for lanes. Zoom and pitch
    /// ease towards their target instead of jumping.
    private func follow(_ pose: NavPose) {
        let now = Date()
        let dt = min(0.1, max(0, now.timeIntervalSince(lastFrame)))
        lastFrame = now
        let approaching = !nav.arrived && pose.distanceToManeuver < max(250, pose.speed * 15)
        let targetZoom: Double = approaching ? 170 : (pose.speed > 25 ? 1300 : 650)
        let targetPitch: Double = approaching ? 62 : 50
        let ease = 1 - exp(-dt / 0.7)
        zoom += (targetZoom - zoom) * ease
        pitch += (targetPitch - pitch) * ease
        let ahead = NavigationService.offset(pose.coordinate, heading: pose.heading, meters: zoom * (0.18 + 0.10 * (zoom - 170) / (650 - 170)).clamped(0.18, 0.28))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position = .camera(MapCamera(centerCoordinate: ahead, distance: zoom, heading: pose.heading, pitch: pitch))
        }
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(high, Swift.max(low, self)) }
}

/// The pace note that is always on screen: the next corner with its live
/// distance, or the straight up to it ("Gerade") when it is far away.
private struct RallyChip: View {
    private var nav: NavigationService { .shared }

    var body: some View {
        let along = nav.pose?.along
        let note = nav.nextRallyNote
        let distance: Double = {
            if let note, let along { return max(0, note.along - along) }
            if note != nil { return nav.distanceToRallyNote }
            return nav.pose?.remainingDistance ?? nav.remainingDistance
        }()
        let near = note != nil && distance < 1000
        HStack(spacing: 8) {
            Image(systemName: near ? note!.symbol : "arrow.up")
                .font(.headline)
                .frame(width: 22)
            Text(near ? note!.display : (note == nil ? "Gerade bis zum Ziel" : "Gerade"))
                .font(.headline)
                .layoutPriority(1)
            Text(NavigationService.displayDistance(distance))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
                .fixedSize()
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular.tint(Color.orange.opacity(near ? 0.6 : 0.35)), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// Distance to the next maneuver, counting down live.
private struct ManeuverDistanceText: View {
    private var nav: NavigationService { .shared }

    var body: some View {
        Text(nav.isRerouting ? "Neue Route …" : NavigationService.displayDistance(nav.pose?.distanceToManeuver ?? nav.distanceToManeuver))
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .monospacedDigit()
    }
}

/// Live speed with the speed-limit sign next to it, like Apple Maps.
private struct LiveSpeedCluster: View {
    private var nav: NavigationService { .shared }
    private var limits: SpeedLimitService { .shared }

    var body: some View {
        let kmh = Int(((nav.pose?.speed ?? nav.speed) * 3.6).rounded())
        let limit = limits.current
        let allowed = limit?.kmh ?? 0
        let over = allowed > 7 && kmh > allowed + 3
        HStack(spacing: -8) {
            VStack(spacing: -2) {
                Text("\(kmh)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(over ? Color.red : Color.primary)
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

/// German traffic signs for the current limit:
/// - limit: white disc, red ring, black number (walking pace: a walker);
/// - no limit (motorway): the blue "Richtgeschwindigkeit 130" sign;
/// - electronic signs: black disc with a white ring and "var.", since no
///   data source knows what they currently show.
/// Limits derived from the StVO rules (not signposted in the map data) are
/// shown paler.
struct SpeedLimitSign: View {
    let limit: SpeedLimit

    var body: some View {
        sign
            .frame(width: 56, height: 56)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .opacity(limit.estimated ? 0.62 : 1)
            .accessibilityLabel(label)
    }

    @ViewBuilder
    private var sign: some View {
        switch limit.kind {
        case .limit(let value):
            ZStack {
                Circle().fill(.white)
                Circle().strokeBorder(Color(red: 0.86, green: 0.1, blue: 0.1), lineWidth: 6)
                if value <= 7 {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.black)
                } else {
                    Text("\(value)")
                        .font(.system(size: value >= 100 ? 18 : 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .monospacedDigit()
                }
            }
            .clipShape(.circle)
        case .none:
            Text("130")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Color(red: 0.0, green: 0.34, blue: 0.72), in: .rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white, lineWidth: 2).padding(3))
        case .variable:
            ZStack {
                Circle().fill(.black)
                Circle().strokeBorder(.white, lineWidth: 4).padding(3)
                Text("var.")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }

    private var label: String {
        let suffix = limit.estimated ? ", geschätzt" : ""
        switch limit.kind {
        case .limit(let value): return (value <= 7 ? "Schrittgeschwindigkeit" : "Tempolimit \(value)") + suffix
        case .none: return "Kein Tempolimit, Richtgeschwindigkeit 130" + suffix
        case .variable: return "Wechselnde Anzeige"
        }
    }
}

/// The car marker: a blue arrow or the user's pixel car.
struct NavigationPuck: View {
    var style: String
    /// Arrow direction relative to the map's up (0 while following).
    var rotation: Double = 0
    /// The car image, loaded once by the map layer (not per frame).
    var image: UIImage = DefaultPixelCar.frontImage

    static let markerChanged = Notification.Name("apexNavMarkerChanged")

    var body: some View {
        if style == "car" {
            PixelImage(image: image)
                .frame(width: 58, height: 40)
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
                    .rotationEffect(.degrees(rotation))
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
    @State private var photoItem: PhotosPickerItem?
    @State private var markerImage: UIImage = DefaultPixelCar.frontImage
    @State private var processing = false

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
                Section {
                    let voice = NavigationService.voiceDescription
                    LabeledContent("Stimme", value: voice.name)
                } header: {
                    Text("Aussprache")
                } footer: {
                    if NavigationService.voiceDescription.isHighQuality {
                        Text("Apex nutzt die beste installierte deutsche Stimme.")
                    } else {
                        Text("Für eine flüssigere, natürlichere Stimme lade eine Premium-Stimme: Einstellungen › Bedienungshilfen › Gesprochene Inhalte › Stimmen › Deutsch, z. B. „Anna (Premium)“. Apex nimmt sie danach automatisch.")
                    }
                }
                Section {
                    Picker("Markierung", selection: $puckStyle) {
                        Text("Pfeil").tag("arrow")
                        Text("Eigenes Auto").tag("car")
                    }
                    .pickerStyle(.segmented)
                    if puckStyle == "car" {
                        HStack(spacing: 14) {
                            PixelImage(image: markerImage)
                                .frame(width: 64, height: 44)
                                .overlay {
                                    if processing { ProgressView() }
                                }
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Text("Eigenes Bild wählen")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                } header: {
                    Text("Markierung")
                } footer: {
                    Text("Ein Foto wird automatisch freigestellt und zu Pixel-Art. Gilt für das aktive Auto.")
                }
            }
            .task { markerImage = Persistence.activeCar()?.navImage ?? DefaultPixelCar.frontImage }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await useMarker(item) }
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

    /// Same pipeline as the garage editor: photos are cut out and pixelated.
    private func useMarker(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let car = Persistence.activeCar() else { return }
        processing = true
        let model = CarImageModel(slot: .nav, data: nil)
        await model.load(data)
        if let result = model.imageData {
            car.navImageData = result
            Persistence.save()
            markerImage = car.navImage
            NotificationCenter.default.post(name: NavigationPuck.markerChanged, object: nil)
        }
        processing = false
        photoItem = nil
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
