import AppIntents
import CoreLocation
import MapKit
import SwiftData

// Siri and Shortcuts. App Shortcuts need no Siri entitlement, so they also
// work with a free Apple ID: the phrases below are available right after
// installation ("Hey Siri, starte eine Fahrt mit Apex").

struct StartDriveIntent: AppIntent {
    static let title: LocalizedStringResource = "Fahrt starten"
    static let description = IntentDescription("Startet die Aufzeichnung einer Fahrt.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let location = LocationService.shared
        location.start()
        guard location.authorization.isAuthorized else {
            return .result(dialog: "Apex braucht deinen Standort. Öffne die App einmal und erlaube ihn.")
        }
        if location.isRecording {
            return .result(dialog: "Es läuft schon eine Fahrt.")
        }
        location.startManualDrive()
        return .result(dialog: "Fahrt gestartet. Gute Fahrt!")
    }
}

struct StopDriveIntent: AppIntent {
    static let title: LocalizedStringResource = "Fahrt beenden"
    static let description = IntentDescription("Beendet und speichert die laufende Fahrt.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let location = LocationService.shared
        guard location.isRecording else {
            return .result(dialog: "Gerade läuft keine Fahrt.")
        }
        let distance = Fmt.distance(location.liveDistance)
        let duration = Fmt.duration(location.liveDuration)
        location.stopDrive()
        return .result(dialog: "Fahrt gespeichert: \(distance) in \(duration).")
    }
}

struct DriveStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Fahrtstatus"
    static let description = IntentDescription("Sagt dir Tempo, Strecke und Dauer der laufenden oder letzten Fahrt.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let location = LocationService.shared
        if location.isRecording {
            let speed = Int((location.speed * 3.6).rounded())
            let text = "Du bist seit \(Fmt.duration(location.liveDuration)) unterwegs, hast \(Fmt.distance(location.liveDistance)) geschafft und fährst gerade \(speed) km/h."
            return .result(dialog: "\(text)")
        }
        var descriptor = FetchDescriptor<Drive>(sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let last = try? Persistence.context.fetch(descriptor).first else {
            return .result(dialog: "Du hast noch keine Fahrt aufgezeichnet.")
        }
        let text = "Gerade läuft keine Fahrt. Deine letzte: \(last.displayTitle), \(Fmt.distance(last.distance)) in \(Fmt.duration(last.duration)), höchstens \(Fmt.kmh(last.maxSpeed))."
        return .result(dialog: "\(text)")
    }
}

struct CheapestFuelIntent: AppIntent {
    static let title: LocalizedStringResource = "Günstigste Tankstelle"
    static let description = IntentDescription("Sucht die günstigste offene Tankstelle in deiner Nähe für den Kraftstoff deines Autos.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let fuel = Persistence.activeCar()?.fuelType ?? SharedStore.fuelType
        guard let coordinate = LocationService.shared.lastLocation?.coordinate ?? SharedStore.lastLocation else {
            return .result(dialog: "Ich kenne deinen Standort noch nicht. Öffne Apex einmal.")
        }
        var stations = SharedStore.cachedStations
        if let fresh = try? await FuelAPI.reachableStations(
            near: coordinate,
            radiusKm: SharedStore.fuelRadiusKm,
            fuel: fuel,
            apiKey: SharedStore.apiKey
        ) {
            stations = fresh
            SharedStore.saveStations(fresh)
        }
        guard let station = stations.first else {
            return .result(dialog: "Im Umkreis hat gerade keine Tankstelle geöffnet.")
        }
        let price = station.price.formatted(.number.precision(.fractionLength(3)))
        let distance = Fmt.distance(station.shownKm * 1000)
        let way = station.roadKm != nil ? "mit dem Auto" : "Luftlinie"
        let text = "\(station.displayName), \(station.address): \(price) Euro für \(fuel.title), \(distance) \(way)."
        return .result(dialog: "\(text)")
    }
}

struct DrivingConditionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Fahrbedingungen"
    static let description = IntentDescription("Sagt dir Wetter und Fahrbedingungen an deinem Standort.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let coordinate = LocationService.shared.lastLocation?.coordinate ?? SharedStore.lastLocation else {
            return .result(dialog: "Ich kenne deinen Standort noch nicht. Öffne Apex einmal.")
        }
        guard let weather = try? await WeatherService.fetch(coordinate) else {
            return .result(dialog: "Das Wetter konnte ich gerade nicht laden.")
        }
        let conditions = DrivingConditions(weather: weather)
        let warnings = conditions.items.filter { $0.level != .good }.map(\.title)
        var text = "\(conditions.headline). \(Int(weather.temperature.rounded())) Grad, \(weather.condition.text)."
        if !warnings.isEmpty {
            text += " Achtung: \(warnings.joined(separator: ", "))."
        }
        return .result(dialog: "\(text)")
    }
}

struct NavigateIntent: AppIntent {
    static let title: LocalizedStringResource = "Navigieren"
    static let description = IntentDescription("Startet die Navigation zu einem Ziel – in Apex oder in Apple Karten, je nach Einstellung.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Ziel", requestValueDialog: "Wohin möchtest du?")
    var destination: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = destination
        if let here = LocationService.shared.lastLocation?.coordinate ?? SharedStore.lastLocation {
            request.region = MKCoordinateRegion(center: here, latitudinalMeters: 100_000, longitudinalMeters: 100_000)
        }
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
            return .result(dialog: "Ich habe \(destination) nicht gefunden.")
        }
        let name = item.name ?? destination
        RecentDestination.remember(item, subtitle: "")
        if (SharedStore.defaults.string(forKey: "navigationTarget") ?? "apex") == "maps" {
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            return .result(dialog: "Ich öffne Apple Karten nach \(name).")
        }
        guard let route = await NavigationService.shared.routes(to: item).first else {
            return .result(dialog: "Ich habe keine Route nach \(name) gefunden.")
        }
        NavigationService.shared.start(route: route, to: item)
        return .result(dialog: "Navigation nach \(name) gestartet.")
    }
}

struct ApexShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NavigateIntent(),
            phrases: [
                "Navigiere mit \(.applicationName)",
                "Starte die Navigation in \(.applicationName)",
                "\(.applicationName) Navigation"
            ],
            shortTitle: "Navigieren",
            systemImageName: "location.north.line.fill"
        )
        AppShortcut(
            intent: StartDriveIntent(),
            phrases: [
                "Starte eine Fahrt mit \(.applicationName)",
                "Fahrt starten in \(.applicationName)",
                "\(.applicationName) Fahrt starten"
            ],
            shortTitle: "Fahrt starten",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StopDriveIntent(),
            phrases: [
                "Beende die Fahrt in \(.applicationName)",
                "Fahrt beenden in \(.applicationName)",
                "\(.applicationName) Fahrt beenden"
            ],
            shortTitle: "Fahrt beenden",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: DriveStatusIntent(),
            phrases: [
                "Wie läuft meine Fahrt in \(.applicationName)",
                "Fahrtstatus in \(.applicationName)",
                "\(.applicationName) Status"
            ],
            shortTitle: "Fahrtstatus",
            systemImageName: "speedometer"
        )
        AppShortcut(
            intent: CheapestFuelIntent(),
            phrases: [
                "Wo ist die günstigste Tankstelle in \(.applicationName)",
                "Günstig tanken mit \(.applicationName)",
                "\(.applicationName) Tankstelle"
            ],
            shortTitle: "Günstigste Tankstelle",
            systemImageName: "fuelpump.fill"
        )
        AppShortcut(
            intent: DrivingConditionsIntent(),
            phrases: [
                "Wie sind die Fahrbedingungen in \(.applicationName)",
                "Fahrwetter in \(.applicationName)",
                "\(.applicationName) Wetter"
            ],
            shortTitle: "Fahrbedingungen",
            systemImageName: "cloud.sun.fill"
        )
    }
}
