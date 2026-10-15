import WidgetKit
import SwiftUI
import CoreLocation
import UIKit

struct FuelEntry: TimelineEntry {
    let date: Date
    let car: UIImage
    let carName: String
    let fuel: FuelType
    let stations: [FuelStation]
    let note: String?

    static var sample: FuelEntry {
        FuelEntry(
            date: Date(),
            car: DefaultPixelCar.frontImage,
            carName: "Mein Auto",
            fuel: .e10,
            stations: [
                FuelStation(id: "1", name: "Aral", brand: "ARAL", street: "Hauptstr.", houseNumber: "1", place: "Köln", lat: 0, lng: 0, dist: 1.2, price: 1.689, isOpen: true),
                FuelStation(id: "2", name: "JET", brand: "JET", street: "Ring", houseNumber: "5", place: "Köln", lat: 0, lng: 0, dist: 2.4, price: 1.709, isOpen: true),
                FuelStation(id: "3", name: "Shell", brand: "Shell", street: "Allee", houseNumber: "9", place: "Köln", lat: 0, lng: 0, dist: 3.1, price: 1.739, isOpen: true)
            ],
            note: nil
        )
    }
}

struct FuelProvider: TimelineProvider {
    func placeholder(in context: Context) -> FuelEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (FuelEntry) -> Void) {
        if context.isPreview {
            completion(.sample)
        } else {
            completion(Self.cachedEntry(note: nil))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FuelEntry>) -> Void) {
        Task {
            let entry = await Self.freshEntry()
            let next = Date().addingTimeInterval(30 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    static func cachedEntry(note: String?) -> FuelEntry {
        FuelEntry(
            date: Date(),
            car: SharedStore.loadCarImage() ?? DefaultPixelCar.frontImage,
            carName: SharedStore.carName,
            fuel: SharedStore.fuelType,
            stations: SharedStore.cachedStations,
            note: note
        )
    }

    /// Loads current prices for the last known location. Falls back to the
    /// app's cached list when offline or without a location.
    static func freshEntry() async -> FuelEntry {
        guard let coordinate = SharedStore.lastLocation else {
            return cachedEntry(note: "Öffne Apex für deinen Standort")
        }
        do {
            let stations = try await FuelAPI.stations(
                near: coordinate,
                radiusKm: SharedStore.fuelRadiusKm,
                fuel: SharedStore.fuelType,
                apiKey: SharedStore.apiKey
            )
            SharedStore.saveStations(stations)
            return cachedEntry(note: stations.isEmpty ? "Keine Tankstelle offen" : nil)
        } catch {
            return cachedEntry(note: nil)
        }
    }
}

struct FuelWidgetView: View {
    let entry: FuelEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        case .accessoryCircular:
            circular
        case .accessoryInline:
            inline
        case .systemMedium:
            medium
        default:
            small
        }
    }

    /// Silhouette version of the car for the monochrome lock screen.
    private var lockCar: UIImage { LockScreenCar.make(from: entry.car) }

    // Lock screen: car on a tile with the fuel type, then the three cheapest
    // stations. The cheapest one is large; the others step back in opacity,
    // so the widget has a clear hierarchy without colour.
    private var rectangular: some View {
        HStack(spacing: 8) {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 3) {
                    PixelImage(image: lockCar)
                        .frame(maxWidth: 42, maxHeight: 26)
                    Text(entry.fuel.shortTitle)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 52)
            .clipShape(.rect(cornerRadius: 12))
            .widgetAccentable()

            if let cheapest = entry.stations.first {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(cheapest.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        PriceText(price: cheapest.price, size: 19, weight: .bold)
                    }
                    ForEach(entry.stations.dropFirst().prefix(2)) { station in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(station.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            PriceText(price: station.price, size: 12, weight: .semibold)
                        }
                        .opacity(0.65)
                    }
                }
            } else {
                Text(entry.note ?? "Keine Preise")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // Lock screen, round: car silhouette and the cheapest price.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                PixelImage(image: lockCar)
                    .frame(maxWidth: 32, maxHeight: 16)
                if let cheapest = entry.stations.first {
                    PriceText(price: cheapest.price, size: 13, weight: .bold)
                } else {
                    Text(entry.fuel.shortTitle)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
            }
        }
        .widgetAccentable()
    }

    // Lock screen, one line above the clock.
    @ViewBuilder
    private var inline: some View {
        if let cheapest = entry.stations.first {
            Label("\(entry.fuel.shortTitle) \(PriceFormat.parts(cheapest.price).main)\(PriceFormat.parts(cheapest.price).last) · \(cheapest.displayName)", systemImage: "fuelpump.fill")
        } else {
            Label(entry.fuel.title, systemImage: "fuelpump.fill")
        }
    }
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            PixelImage(image: entry.car)
                .frame(maxWidth: .infinity, maxHeight: 50)
            if let cheapest = entry.stations.first {
                Text("\(entry.fuel.title) · \(cheapest.displayName)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                PriceText(price: cheapest.price, size: 30, weight: .heavy)
                Text("\(Fmt1.km(cheapest.dist)) entfernt")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.note ?? "Keine Preise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                PixelImage(image: entry.car)
                    .frame(maxWidth: 130, maxHeight: 70)
                Text(entry.carName)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.fuel.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if entry.stations.isEmpty {
                    Text(entry.note ?? "Keine Preise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entry.stations.prefix(3)) { station in
                        HStack {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(station.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(Fmt1.km(station.dist))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            PriceText(price: station.price, size: 18, weight: .heavy)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private enum Fmt1 {
    static func km(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) km"
    }
}

struct WidgetBackground: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryRectangular || family == .accessoryCircular || family == .accessoryInline {
            Color.clear
        } else {
            LinearGradient(
                colors: [Color(red: 0.98, green: 0.62, blue: 0.25).opacity(0.25), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

struct ApexFuelWidget: Widget {
    let kind = "ApexFuelWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FuelProvider()) { entry in
            FuelWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackground()
                }
                .widgetURL(URL(string: "apex://garage"))
        }
        .configurationDisplayName("Pixel-Auto & Sprit")
        .description("Dein Pixel-Auto und die günstigsten Tankstellen in der Nähe.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline, .systemSmall, .systemMedium])
    }
}

@main
struct ApexWidgetBundle: WidgetBundle {
    var body: some Widget {
        ApexFuelWidget()
    }
}
