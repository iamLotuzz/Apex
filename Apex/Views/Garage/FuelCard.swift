import SwiftUI

struct FuelCard: View {
    let stations: [FuelStation]
    let fuel: FuelType
    let loading: Bool
    let error: String?
    let updated: Date?
    var onOpenSettings: () -> Void

    @Environment(\.openURL) private var openURL

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
                    Text(error ?? "Keine geöffneten Tankstellen im Umkreis gefunden.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(stations.prefix(5).enumerated()), id: \.element.id) { index, station in
                        Button {
                            if let url = URL(string: "maps://?daddr=\(station.lat),\(station.lng)&dirflg=d") {
                                openURL(url)
                            }
                        } label: {
                            StationRow(rank: index + 1, station: station, cheapest: stations.first?.price ?? station.price)
                        }
                        .buttonStyle(.plain)
                        if index < min(stations.count, 5) - 1 {
                            Divider()
                        }
                    }
                }
            }

            HStack {
                Text("Preise: Tankerkönig / MTS-K (CC BY 4.0)")
                Spacer()
                if let updated {
                    Text(updated.formatted(date: .omitted, time: .shortened))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

private struct StationRow: View {
    let rank: Int
    let station: FuelStation
    let cheapest: Double

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
                Text("\(station.address) · \(Fmt.number(station.dist, digits: 1)) km")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                PriceText(price: station.price, size: 20)
                if station.price > cheapest + 0.0005 {
                    Text("+\(Int(((station.price - cheapest) * 100).rounded())) ct")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}
