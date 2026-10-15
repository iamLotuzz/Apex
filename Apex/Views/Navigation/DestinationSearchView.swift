import SwiftUI
import MapKit
import Observation

/// Autocomplete for destinations via Apple's search.
@MainActor
@Observable
final class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ query: String) {
        if let here = LocationService.shared.lastLocation?.coordinate ?? SharedStore.lastLocation {
            completer.region = MKCoordinateRegion(center: here, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = []
        } else {
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        MainActor.assumeIsolated { self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}

struct RecentDestination: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var subtitle: String
    var lat: Double
    var lon: Double

    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        item.name = name
        return item
    }

    private static let key = "recentDestinations"

    static func load() -> [RecentDestination] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentDestination].self, from: data)) ?? []
    }

    static func remember(_ item: MKMapItem, subtitle: String) {
        let coordinate = item.placemark.coordinate
        var list = load().filter { Geo.distance(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon), coordinate) > 50 }
        list.insert(RecentDestination(name: item.name ?? "Ziel", subtitle: subtitle, lat: coordinate.latitude, lon: coordinate.longitude), at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(8))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct SelectedDestination: Identifiable {
    let id = UUID()
    let item: MKMapItem
    let subtitle: String
}

/// The Navi tab, laid out like Apple Maps: the map fills the screen and one
/// glass panel at the bottom moves through search → results → routes.
struct DestinationSearchView: View {
    @State private var query = ""
    @State private var completer: SearchCompleter
    @State private var recents: [RecentDestination] = RecentDestination.load()
    @State private var destination: SelectedDestination?
    @State private var routes: [MKRoute] = []
    @State private var selectedRoute = 0
    @State private var loading = false
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @FocusState private var searchFocused: Bool
    @AppStorage("navigationTarget", store: SharedStore.defaults) private var target = "apex"

    init() {
        _completer = State(initialValue: SearchCompleter())
    }

    private let routeBlue = Color(red: 0.16, green: 0.53, blue: 1.0)

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $position) {
                UserAnnotation()
                ForEach(Array(routes.enumerated()), id: \.offset) { index, route in
                    MapPolyline(route.polyline)
                        .stroke(index == selectedRoute ? routeBlue : Color.gray.opacity(0.55),
                                style: StrokeStyle(lineWidth: index == selectedRoute ? 8 : 6, lineCap: .round, lineJoin: .round))
                }
                if let destination {
                    Marker(destination.item.name ?? "Ziel", systemImage: "flag.checkered", coordinate: destination.item.placemark.coordinate)
                        .tint(.red)
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll, showsTraffic: true))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }

            panel
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .onChange(of: query) { _, newValue in completer.update(newValue) }
        .animation(.snappy, value: destination?.id)
        .animation(.snappy, value: searchFocused)
    }

    // MARK: Panel

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let destination {
                routeContent(destination)
            } else {
                searchField
                if query.isEmpty {
                    recentContent
                } else {
                    resultContent
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Ziel suchen", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Suche löschen")
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.fill.tertiary, in: .capsule)
    }

    @ViewBuilder
    private var recentContent: some View {
        if recents.isEmpty {
            Text("Wohin soll's gehen?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Zuletzt")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                ForEach(recents.prefix(searchFocused ? 6 : 3)) { recent in
                    Button {
                        choose(recent.mapItem, subtitle: recent.subtitle)
                    } label: {
                        DestinationRow(title: recent.name, subtitle: recent.subtitle, symbol: "clock.fill", tint: .gray)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var resultContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(completer.results, id: \.self) { result in
                    Button {
                        select(result)
                    } label: {
                        DestinationRow(title: result.title, subtitle: result.subtitle, symbol: "mappin.circle.fill", tint: .red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 340)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func routeContent(_ destination: SelectedDestination) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.item.name ?? "Ziel")
                        .font(.title2.bold())
                        .lineLimit(1)
                    if !destination.subtitle.isEmpty {
                        Text(destination.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(.fill.tertiary, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Schließen")
            }

            if loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Route wird berechnet …")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else if routes.isEmpty {
                Text("Keine Route gefunden.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(routes.enumerated()), id: \.offset) { index, route in
                        Button {
                            selectedRoute = index
                        } label: {
                            routeRow(route, index: index)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Picker("Navigieren", selection: $target) {
                Text("In Apex").tag("apex")
                Text("In Apple Karten").tag("maps")
            }
            .pickerStyle(.segmented)

            Button {
                go(destination)
            } label: {
                Text("Los")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .disabled(routes.isEmpty && target == "apex")
        }
    }

    private func routeRow(_ route: MKRoute, index: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.duration(route.expectedTravelTime))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                    if index == 0 {
                        Text("Schnellste")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Text("\(NavigationService.displayDistance(route.distance)) · \(route.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: index == selectedRoute ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(index == selectedRoute ? routeBlue : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.fill.quaternary, in: .rect(cornerRadius: 18))
        .contentShape(.rect)
    }

    // MARK: Actions

    private func select(_ completion: MKLocalSearchCompletion) {
        Task {
            let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
            if let item = response?.mapItems.first {
                choose(item, subtitle: completion.subtitle)
            }
        }
    }

    private func choose(_ item: MKMapItem, subtitle: String) {
        searchFocused = false
        destination = SelectedDestination(item: item, subtitle: subtitle)
        routes = []
        selectedRoute = 0
        loading = true
        Task {
            let found = await NavigationService.shared.routes(to: item)
            routes = found
            loading = false
            if let first = found.first {
                let rect = first.polyline.boundingMapRect
                withAnimation {
                    position = .rect(rect.insetBy(dx: -rect.width * 0.2, dy: -rect.height * 0.6))
                }
            }
        }
    }

    private func close() {
        destination = nil
        routes = []
        withAnimation { position = .userLocation(fallback: .automatic) }
    }

    private func go(_ destination: SelectedDestination) {
        RecentDestination.remember(destination.item, subtitle: destination.subtitle)
        recents = RecentDestination.load()
        if target == "maps" {
            destination.item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        } else if routes.indices.contains(selectedRoute) {
            NavigationService.shared.start(route: routes[selectedRoute], to: destination.item)
        }
        query = ""
        close()
    }
}

private struct DestinationRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(.rect)
    }
}
