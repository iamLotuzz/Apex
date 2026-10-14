import Foundation
import CoreLocation
import UIKit

/// Data shared between the app and the widget through the App Group.
enum SharedStore {
    static let defaultGroupID = "group.de.aslaframes.apex"

    /// AltStore/SideStore rename App Groups when they re-sign the app and write the
    /// real identifiers into the `ALTAppGroups` Info.plist key. The widget lives in
    /// `Apex.app/PlugIns/`, so it also checks the containing app's Info.plist.
    static let groupID: String = {
        if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String],
           let first = groups.first {
            return first
        }
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if appURL.pathExtension == "app",
           let appBundle = Bundle(url: appURL),
           let groups = appBundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String],
           let first = groups.first {
            return first
        }
        return defaultGroupID
    }()

    static let defaults: UserDefaults = UserDefaults(suiteName: groupID) ?? .standard

    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static var isGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
    }

    enum Key {
        static let autoTracking = "autoTracking"
        static let startSpeedKmh = "startSpeedKmh"
        static let stopMinutes = "stopMinutes"
        static let fuelType = "fuelType"
        static let apiKey = "tankerkoenigApiKey"
        static let fuelRadiusKm = "fuelRadiusKm"
        static let lastLat = "lastLatitude"
        static let lastLon = "lastLongitude"
        static let lastLocationDate = "lastLocationDate"
        static let cachedStations = "cachedStations"
        static let cachedStationsDate = "cachedStationsDate"
        static let carName = "activeCarName"
        static let onboardingDone = "onboardingDone"
        static let lapReference = "lapReference"
        static let lastCheapestPrice = "lastCheapestPrice"
        static let instantStart = "instantStart"
        static let notifyOnStart = "notifyOnStart"
        static let parkedLat = "parkedLatitude"
        static let parkedLon = "parkedLongitude"
        static let parkedDate = "parkedDate"
    }

    /// Keeps low-power location running between drives so a drive starts
    /// within seconds instead of after iOS wakes the app hundreds of metres later.
    static var instantStart: Bool {
        get { defaults.object(forKey: Key.instantStart) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.instantStart) }
    }

    static var notifyOnStart: Bool {
        get { defaults.object(forKey: Key.notifyOnStart) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.notifyOnStart) }
    }

    /// Where the last drive ended, used as the start point of the next drive.
    static var parked: (coordinate: CLLocationCoordinate2D, date: Date)? {
        guard let lat = defaults.object(forKey: Key.parkedLat) as? Double,
              let lon = defaults.object(forKey: Key.parkedLon) as? Double,
              let date = defaults.object(forKey: Key.parkedDate) as? Date else { return nil }
        return (CLLocationCoordinate2D(latitude: lat, longitude: lon), date)
    }

    static func saveParked(_ coordinate: CLLocationCoordinate2D, date: Date) {
        defaults.set(coordinate.latitude, forKey: Key.parkedLat)
        defaults.set(coordinate.longitude, forKey: Key.parkedLon)
        defaults.set(date, forKey: Key.parkedDate)
    }

    // MARK: Settings

    static var autoTracking: Bool {
        get { defaults.object(forKey: Key.autoTracking) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoTracking) }
    }

    static var startSpeedKmh: Double {
        get { defaults.object(forKey: Key.startSpeedKmh) as? Double ?? 10 }
        set { defaults.set(newValue, forKey: Key.startSpeedKmh) }
    }

    static var stopMinutes: Double {
        get { defaults.object(forKey: Key.stopMinutes) as? Double ?? 4 }
        set { defaults.set(newValue, forKey: Key.stopMinutes) }
    }

    static var fuelType: FuelType {
        get { FuelType(rawValue: defaults.string(forKey: Key.fuelType) ?? "") ?? .e10 }
        set { defaults.set(newValue.rawValue, forKey: Key.fuelType) }
    }

    /// The user's Tankerkönig key, or the public demo key when none is set.
    static var apiKey: String {
        get {
            let key = defaults.string(forKey: Key.apiKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return key.isEmpty ? FuelAPI.demoKey : key
        }
        set { defaults.set(newValue, forKey: Key.apiKey) }
    }

    static var usesDemoKey: Bool { apiKey == FuelAPI.demoKey }

    static var fuelRadiusKm: Double {
        get { defaults.object(forKey: Key.fuelRadiusKm) as? Double ?? 5 }
        set { defaults.set(newValue, forKey: Key.fuelRadiusKm) }
    }

    static var carName: String {
        get { defaults.string(forKey: Key.carName) ?? "Mein Auto" }
        set { defaults.set(newValue, forKey: Key.carName) }
    }

    static var lastCheapestPrice: Double? {
        get { defaults.object(forKey: Key.lastCheapestPrice) as? Double }
        set { defaults.set(newValue, forKey: Key.lastCheapestPrice) }
    }

    // MARK: Location

    static var lastLocation: CLLocationCoordinate2D? {
        guard let lat = defaults.object(forKey: Key.lastLat) as? Double,
              let lon = defaults.object(forKey: Key.lastLon) as? Double else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static var lastLocationDate: Date? {
        defaults.object(forKey: Key.lastLocationDate) as? Date
    }

    static func saveLastLocation(_ coordinate: CLLocationCoordinate2D, date: Date = Date()) {
        defaults.set(coordinate.latitude, forKey: Key.lastLat)
        defaults.set(coordinate.longitude, forKey: Key.lastLon)
        defaults.set(date, forKey: Key.lastLocationDate)
    }

    // MARK: Fuel station cache

    static var cachedStations: [FuelStation] {
        guard let data = defaults.data(forKey: Key.cachedStations) else { return [] }
        return (try? JSONDecoder().decode([FuelStation].self, from: data)) ?? []
    }

    static var cachedStationsDate: Date? {
        defaults.object(forKey: Key.cachedStationsDate) as? Date
    }

    static func saveStations(_ stations: [FuelStation]) {
        if let data = try? JSONEncoder().encode(stations) {
            defaults.set(data, forKey: Key.cachedStations)
            defaults.set(Date(), forKey: Key.cachedStationsDate)
        }
        if let cheapest = stations.first?.price {
            lastCheapestPrice = cheapest
        }
    }

    // MARK: Car image

    static var carImageURL: URL {
        containerURL.appendingPathComponent("active-car.png")
    }

    static func saveCarImage(_ data: Data?) {
        if let data {
            try? data.write(to: carImageURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: carImageURL)
        }
    }

    static func loadCarImage() -> UIImage? {
        guard let data = try? Data(contentsOf: carImageURL) else { return nil }
        return UIImage(data: data)
    }
}
