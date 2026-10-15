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

/// Search tab: type a destination, pick it, see the routes.
struct DestinationSearchView: View {
    @State private var query = ""
    @State private var completer: SearchCompleter
    @State private var selected: SelectedDestination?
    @State private var recents: [RecentDestination] = RecentDestination.load()
    @State private var searching = false

    init() {
        _completer = State(initialValue: SearchCompleter())
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    if recents.isEmpty {
                        ContentUnavailableView("Wohin soll's gehen?", systemImage: "map", description: Text("Suche oben nach einer Adresse oder einem Ort."))
                            .listRowBackground(Color.clear)
                    } else {
                        Section("Zuletzt") {
                            ForEach(recents) { recent in
                                Button {
                                    selected = SelectedDestination(item: recent.mapItem, subtitle: recent.subtitle)
                                } label: {
                                    DestinationRow(title: recent.name, subtitle: recent.subtitle, symbol: "clock.fill", tint: .gray)
                                }
                            }
                        }
                    }
                } else {
                    ForEach(completer.results, id: \.self) { result in
                        Button {
                            select(result)
                        } label: {
                            DestinationRow(title: result.title, subtitle: result.subtitle, symbol: "mappin.circle.fill", tint: .red)
                        }
                    }
                }
            }
            .navigationTitle("Navigation")
            .searchable(text: $query, prompt: "Ziel suchen")
            .onChange(of: query) { _, newValue in completer.update(newValue) }
            .overlay {
                if searching { ProgressView() }
            }
            .sheet(item: $selected, onDismiss: { recents = RecentDestination.load() }) { destination in
                RoutePreviewSheet(destination: destination)
            }
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        searching = true
        Task {
            let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
            searching = false
            if let item = response?.mapItems.first {
                selected = SelectedDestination(item: item, subtitle: completion.subtitle)
            }
        }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Routes to the chosen destination, the "In Apex / In Apple Karten" switch
/// and the green Los button – like the route card in Apple Maps.
struct RoutePreviewSheet: View {
    let destination: SelectedDestination

    @Environment(\.dismiss) private var dismiss
    @AppStorage("navigationTarget", store: SharedStore.defaults) private var target = "apex"
    @State private var routes: [MKRoute] = []
    @State private var selectedIndex = 0
    @State private var loading = true
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Map(position: $position) {
                    ForEach(Array(routes.enumerated()), id: \.offset) { index, route in
                        MapPolyline(route.polyline)
                            .stroke(index == selectedIndex ? Color(red: 0.16, green: 0.53, blue: 1.0) : Color.gray.opacity(0.6),
                                    style: StrokeStyle(lineWidth: index == selectedIndex ? 8 : 6, lineCap: .round, lineJoin: .round))
                    }
                    Marker(destination.item.name ?? "Ziel", systemImage: "flag.checkered", coordinate: destination.item.placemark.coordinate)
                        .tint(.red)
                    UserAnnotation()
                }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll, showsTraffic: true))
                .frame(height: 250)
                .clipShape(.rect(cornerRadius: 24))

                if loading {
                    ProgressView("Route wird berechnet …")
                        .frame(maxHeight: .infinity)
                } else if routes.isEmpty {
                    ContentUnavailableView("Keine Route gefunden", systemImage: "exclamationmark.triangle")
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(routes.enumerated()), id: \.offset) { index, route in
                                Button {
                                    selectedIndex = index
                                } label: {
                                    routeRow(route, index: index)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Picker("Navigieren", selection: $target) {
                    Text("In Apex").tag("apex")
                    Text("In Apple Karten").tag("maps")
                }
                .pickerStyle(.segmented)

                Button {
                    go()
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
            .padding()
            .navigationTitle(destination.item.name ?? "Ziel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .task {
                routes = await NavigationService.shared.routes(to: destination.item)
                loading = false
                if let first = routes.first {
                    position = .rect(first.polyline.boundingMapRect.insetBy(dx: -first.polyline.boundingMapRect.width * 0.15, dy: -first.polyline.boundingMapRect.height * 0.25))
                }
            }
        }
    }

    private func routeRow(_ route: MKRoute, index: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Fmt.duration(route.expectedTravelTime))
                        .font(.system(.title3, design: .rounded).weight(.bold))
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
            Spacer()
            if index == selectedIndex {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color(red: 0.16, green: 0.53, blue: 1.0))
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(index == selectedIndex ? Color(red: 0.16, green: 0.53, blue: 1.0) : Color.clear, lineWidth: 2)
        )
    }

    private func go() {
        RecentDestination.remember(destination.item, subtitle: destination.subtitle)
        if target == "maps" {
            destination.item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        } else if routes.indices.contains(selectedIndex) {
            NavigationService.shared.start(route: routes[selectedIndex], to: destination.item)
        }
        dismiss()
    }
}
