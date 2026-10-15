import SwiftUI
import MapKit

struct FuelCard: View {
    let stations: [FuelStation]
    let fuel: FuelType
    let loading: Bool
    let error: String?
    let updated: Date?
    var onOpenSettings: () -> Void

    @State private var routingTo: String?
    @State private var routeFailed = false

    var body: some View {
        Card(title: "Günstig tanken · \(fuel.title)", symbol: "fuelpump.fill") {
            if SharedStore.usesDemoKey {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Demo-Daten aktiv. Für echte Preise trage einen kostenlosen Tankerkönig-API-Key ein.")
                            .font(.caption)
                        Button("API-Key eintragen", action: onOpenSettings)
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
            }

            if stations.isEmpty {
                if loading {
                    HStack {
                        ProgressView()
                        Text("Tankstellen werden gesucht …")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(error ?? "Keine geöffnete Tankstelle mit dem Auto im Umkreis von \(Int(SharedStore.fuelRadiusKm)) km.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(stations.prefix(5).enumerated()), id: \.element.id) { index, station in
                        Button {
                            navigate(to: station)
                        } label: {
                            StationRow(
                                rank: index + 1,
                                station: station,
                                cheapest: stations.first?.price ?? station.price,
                                routing: routingTo == station.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(routingTo != nil)
                        .contextMenu {
                            Button {
                                navigate(to: station)
                            } label: {
                                Label("In Apex navigieren", systemImage: "location.north.line.fill")
                            }
                            Button {
                                mapItem(station).openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                            } label: {
                                Label("In Apple Karten öffnen", systemImage: "map")
                            }
                        }
                        if index < min(stations.count, 5) - 1 {
                            Divider()
                        }
                    }
                }
            }

            HStack {
                Text("Fahrweg mit dem Auto · max. \(Int(SharedStore.fuelRadiusKm)) km")
                Spacer()
                if let updated {
                    Text(updated.formatted(date: .omitted, time: .shortened))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            Text("Preise: Tankerkönig / MTS-K (CC BY 4.0)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .alert("Keine Route gefunden", isPresented: $routeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Zur Tankstelle konnte gerade keine Route berechnet werden.")
        }
    }

    private func mapItem(_ station: FuelStation) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: station.coordinate))
        item.name = station.displayName
        return item
    }

    /// Tap: fastest route to the station, started in Apex right away.
    private func navigate(to station: FuelStation) {
        routingTo = station.id
        Task {
            let started = await NavigationService.shared.navigate(to: mapItem(station))
            routingTo = nil
            if !started { routeFailed = true }
        }
    }
}

private struct StationRow: View {
    let rank: Int
    let station: FuelStation
    let cheapest: Double
    var routing = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .frame(width: 28, height: 28)
                .background(rank == 1 ? Color.green.opacity(0.2) : Color.secondary.opacity(0.12), in: .circle)
                .foregroundStyle(rank == 1 ? Color.green : Color.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(station.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: station.roadKm != nil ? "car.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                        .imageScale(.small)
                    Text(station.distanceText)
                        .monospacedDigit()
                    Text("· \(station.address)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                PriceText(price: station.price, size: 20)
                if station.price > cheapest + 0.0005 {
                    Text("+\(Int(((station.price - cheapest) * 100).rounded())) ct")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Group {
                if routing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                }
            }
            .frame(width: 28)
            .accessibilityLabel("Navigieren")
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}
