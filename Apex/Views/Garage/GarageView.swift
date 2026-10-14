import SwiftUI
import SwiftData
import CoreLocation
import WidgetKit

struct GarageView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Car.createdAt) private var cars: [Car]
    @Query private var drives: [Drive]
    @Query private var sessions: [TrackSession]

    @State private var weather: WeatherSnapshot?
    @State private var weatherError: String?
    @State private var stations: [FuelStation] = SharedStore.cachedStations
    @State private var stationsUpdated: Date? = SharedStore.cachedStationsDate
    @State private var fuelError: String?
    @State private var loadingFuel = false
    @State private var editingCar: Car?
    @State private var newCarID: UUID?
    @State private var showSettings = false
    @State private var lastRefresh = Date.distantPast
    @State private var statsScope: StatsScope = .car
    @State private var pendingDelete: Car?

    enum StatsScope: Hashable {
        case car, all
    }

    private var location: LocationService { .shared }

    private var activeCar: Car? { cars.first(where: \.isActive) ?? cars.first }

    private var coordinate: CLLocationCoordinate2D? {
        location.lastLocation?.coordinate ?? SharedStore.lastLocation
    }

    /// Changes when the user moves about 1 km, which triggers a refresh.
    private var locationKey: String {
        guard let c = coordinate else { return "none" }
        return "\(Int(c.latitude * 100))/\(Int(c.longitude * 100))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    carStrip
                    hero
                    specs
                    totals
                    WeatherCard(weather: weather, error: weatherError, hasLocation: coordinate != nil)
                    FuelCard(
                        stations: stations,
                        fuel: activeCar?.fuelType ?? SharedStore.fuelType,
                        loading: loadingFuel,
                        error: fuelError,
                        updated: stationsUpdated
                    ) {
                        showSettings = true
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationTitle("Garage")
            .toolbar { toolbar }
            .refreshable { await refresh(force: true) }
            .task(id: locationKey) { await refresh(force: false) }
            .sheet(item: $editingCar, onDismiss: { newCarID = nil }) { car in
                CarEditorView(car: car, isNew: car.id == newCarID, canDelete: cars.count > 1)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .confirmationDialog(
                "\(pendingDelete?.displayName ?? "Auto") löschen?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Löschen", role: .destructive) {
                    if let car = pendingDelete { deleteCar(car) }
                    pendingDelete = nil
                }
            } message: {
                Text("Fahrten und Sessions bleiben erhalten, sind dann aber keinem Auto mehr zugeordnet.")
            }
        }
    }

    // MARK: Car strip

    /// All cars as chips with their front image; tap switches, "+" adds one.
    private var carStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(cars) { car in
                        Button {
                            withAnimation(.snappy) { Persistence.setActive(car) }
                        } label: {
                            HStack(spacing: 8) {
                                PixelImage(image: car.frontImage)
                                    .frame(width: 40, height: 26)
                                Text(car.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 14)
                            .padding(.vertical, 7)
                            .foregroundStyle(car.id == activeCar?.id ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            car.id == activeCar?.id ? .regular.tint(Color.orange).interactive() : .regular.interactive(),
                            in: .capsule
                        )
                        .contextMenu {
                            Button {
                                editingCar = car
                            } label: {
                                Label("Bearbeiten", systemImage: "pencil")
                            }
                            if cars.count > 1 {
                                Button(role: .destructive) {
                                    pendingDelete = car
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                        }
                    }
                    Button {
                        addCar()
                    } label: {
                        Label("Auto", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .padding(.vertical, 2)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: Sections

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            PixelSceneView(car: activeCar?.sideImage ?? DefaultPixelCar.image, weather: weather)
                .frame(height: 250)
            VStack(alignment: .leading, spacing: 2) {
                Text(activeCar?.displayName ?? "Mein Auto")
                    .font(.title2.bold())
                if let subtitle = activeCar?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 30))
        .onTapGesture {
            if let activeCar { editingCar = activeCar }
        }
    }

    @ViewBuilder
    private var specs: some View {
        if let car = activeCar {
            let chips = specChips(car)
            if chips.isEmpty {
                Button {
                    editingCar = car
                } label: {
                    Label("Autodaten eintragen", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(chips, id: \.self) { chip in
                                Text(chip)
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .glassEffect(.regular, in: .capsule)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    private func specChips(_ car: Car) -> [String] {
        var chips: [String] = []
        if let ps = car.powerPS { chips.append("\(ps) PS") }
        if let nm = car.torqueNm { chips.append("\(nm) Nm") }
        if let kg = car.weightKg { chips.append("\(kg.formatted()) kg") }
        if let ratio = car.powerToWeight { chips.append("\(Fmt.number(ratio, digits: 1)) kg/PS") }
        if let ccm = car.displacementCcm { chips.append("\(ccm.formatted()) cm³") }
        if let sprint = car.zeroToHundredSpec { chips.append("0–100 in \(Fmt.number(sprint, digits: 1)) s") }
        if let vmax = car.topSpeedSpec { chips.append("Vmax \(vmax) km/h") }
        if car.powerPS != nil || car.weightKg != nil {
            chips.append(car.drivetrain.title)
            chips.append(car.transmission.title)
        }
        if let consumption = car.consumption { chips.append("\(Fmt.number(consumption, digits: 1)) l/100 km") }
        return chips
    }

    private var totals: some View {
        let perCar = statsScope == .car || cars.count < 2
        let carID = activeCar?.id
        let scopedDrives = perCar ? drives.filter { $0.carID == carID } : drives
        let scopedSessions = perCar ? sessions.filter { $0.carID == carID } : sessions
        let distance = scopedDrives.reduce(0.0) { $0 + $1.distance }
        let time = scopedDrives.reduce(0.0) { $0 + $1.duration }
        let top = scopedDrives.map(\.maxSpeed).max() ?? 0
        let longest = scopedDrives.map(\.distance).max() ?? 0
        let climb = scopedDrives.reduce(0.0) { $0 + $1.elevationGain }
        let laps = scopedSessions.reduce(0) { $0 + $1.lapCount }
        let avg = time > 0 ? distance / time : 0
        let carDistance = drives.filter { $0.carID == carID }.reduce(0.0) { $0 + $1.distance }

        return Card(title: "Gesamtstatistik", symbol: "chart.bar.doc.horizontal") {
            if cars.count > 1 {
                Picker("Statistik für", selection: $statsScope) {
                    Text(activeCar?.displayName ?? "Dieses Auto").tag(StatsScope.car)
                    Text("Alle Autos").tag(StatsScope.all)
                }
                .pickerStyle(.segmented)
            }
            StatGrid {
                StatTile(title: "Gefahren", value: Fmt.km(distance, digits: 0), unit: "km", symbol: "road.lanes", tint: .orange)
                StatTile(title: "Fahrten", value: "\(scopedDrives.count)", symbol: "car.fill", tint: .blue)
                StatTile(title: "Fahrzeit", value: Fmt.duration(time), symbol: "clock.fill", tint: .indigo)
                StatTile(title: "Höchsttempo", value: Fmt.kmhValue(top), unit: "km/h", symbol: "bolt.fill", tint: .purple)
                StatTile(title: "Ø Tempo", value: Fmt.kmhValue(avg), unit: "km/h", symbol: "speedometer", tint: .teal)
                StatTile(title: "Längste Fahrt", value: Fmt.km(longest, digits: 1), unit: "km", symbol: "arrow.left.and.right", tint: .green)
                StatTile(title: "Höhenmeter", value: Int(climb).formatted(), unit: "m", symbol: "mountain.2.fill", tint: .brown)
                StatTile(title: "Track-Runden", value: "\(laps)", unit: "\(scopedSessions.count) Sessions", symbol: "flag.checkered", tint: .red)
                if let car = activeCar, let start = car.odometerStart {
                    StatTile(title: "Kilometerstand", value: Int(start + carDistance / 1000).formatted(), unit: "km", symbol: "gauge.with.needle", tint: .gray)
                }
                if let car = activeCar, let consumption = car.consumption, consumption > 0 {
                    let litres = carDistance / 1000 * consumption / 100
                    if let price = SharedStore.lastCheapestPrice {
                        StatTile(title: "Spritkosten ca.", value: Fmt.euro(litres * price), symbol: "eurosign.circle.fill", tint: .green)
                    } else {
                        StatTile(title: "Kraftstoff", value: Fmt.number(litres, digits: 0), unit: "l", symbol: "drop.fill", tint: .orange)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                if let activeCar { editingCar = activeCar }
            } label: {
                Label("Bearbeiten", systemImage: "square.and.pencil")
            }
            Button {
                showSettings = true
            } label: {
                Label("Einstellungen", systemImage: "gearshape")
            }
        }
    }

    // MARK: Actions

    private func deleteCar(_ car: Car) {
        let wasActive = car.isActive
        let next = cars.first { $0.id != car.id }
        context.delete(car)
        try? context.save()
        if wasActive, let next {
            Persistence.setActive(next)
        }
    }

    private func addCar() {
        let car = Car(nickname: "")
        context.insert(car)
        try? context.save()
        newCarID = car.id
        editingCar = car
    }

    private func refresh(force: Bool) async {
        guard let coordinate else { return }
        if !force && Date().timeIntervalSince(lastRefresh) < 120 && weather != nil { return }
        lastRefresh = Date()

        async let weatherResult = loadWeather(coordinate)
        await loadFuel(coordinate)
        await weatherResult
    }

    private func loadWeather(_ coordinate: CLLocationCoordinate2D) async {
        do {
            weather = try await WeatherService.fetch(coordinate)
            weatherError = nil
        } catch {
            weatherError = "Wetter konnte nicht geladen werden."
        }
    }

    private func loadFuel(_ coordinate: CLLocationCoordinate2D) async {
        loadingFuel = true
        defer { loadingFuel = false }
        let fuel = activeCar?.fuelType ?? SharedStore.fuelType
        do {
            let result = try await FuelAPI.stations(
                near: coordinate,
                radiusKm: SharedStore.fuelRadiusKm,
                fuel: fuel,
                apiKey: SharedStore.apiKey
            )
            stations = result
            stationsUpdated = Date()
            fuelError = nil
            SharedStore.saveStations(result)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            fuelError = error.localizedDescription
        }
    }
}
