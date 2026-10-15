import Foundation
import SwiftData
import UIKit

enum Drivetrain: String, CaseIterable, Identifiable {
    case fwd, rwd, awd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fwd: return "Frontantrieb"
        case .rwd: return "Heckantrieb"
        case .awd: return "Allrad"
        }
    }
}

enum Transmission: String, CaseIterable, Identifiable {
    case manual, automatic, dct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "Schaltgetriebe"
        case .automatic: return "Automatik"
        case .dct: return "Doppelkupplung"
        }
    }
}

@Model
final class Car {
    var id: UUID = UUID()
    var nickname: String = ""
    var make: String = ""
    var modelName: String = ""
    var year: Int?
    var powerPS: Int?
    var torqueNm: Int?
    var weightKg: Int?
    var displacementCcm: Int?
    var drivetrainRaw: String = Drivetrain.rwd.rawValue
    var transmissionRaw: String = Transmission.manual.rawValue
    var fuelTypeRaw: String = FuelType.e10.rawValue
    var consumption: Double?        // l/100 km
    var tankSize: Double?           // litres
    var plate: String = ""
    var odometerStart: Double?      // km when the car was added
    var zeroToHundredSpec: Double?  // seconds
    var topSpeedSpec: Int?          // km/h
    var isActive: Bool = false
    var createdAt: Date = Date()
    /// Side view for the driving scene in the app.
    @Attribute(.externalStorage) var sideImageData: Data?
    /// Front three-quarter view for widgets and icons.
    @Attribute(.externalStorage) var frontImageData: Data?
    /// Own marker for the navigation map; falls back to the front view.
    @Attribute(.externalStorage) var navImageData: Data?

    init(nickname: String = "Mein Auto") {
        self.id = UUID()
        self.nickname = nickname
        self.createdAt = Date()
    }

    var drivetrain: Drivetrain {
        get { Drivetrain(rawValue: drivetrainRaw) ?? .rwd }
        set { drivetrainRaw = newValue.rawValue }
    }

    var transmission: Transmission {
        get { Transmission(rawValue: transmissionRaw) ?? .manual }
        set { transmissionRaw = newValue.rawValue }
    }

    var fuelType: FuelType {
        get { FuelType(rawValue: fuelTypeRaw) ?? .e10 }
        set { fuelTypeRaw = newValue.rawValue }
    }

    var displayName: String {
        if !nickname.isEmpty { return nickname }
        let full = "\(make) \(modelName)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? "Mein Auto" : full
    }

    var subtitle: String {
        var parts: [String] = []
        let full = "\(make) \(modelName)".trimmingCharacters(in: .whitespaces)
        if !full.isEmpty && full != displayName { parts.append(full) }
        if let year { parts.append(String(year)) }
        if !plate.isEmpty { parts.append(plate) }
        return parts.joined(separator: " · ")
    }

    var sideImage: UIImage {
        DecodedImages.image(sideImageData) ?? DefaultPixelCar.image
    }

    var frontImage: UIImage {
        DecodedImages.image(frontImageData) ?? DefaultPixelCar.frontImage
    }

    var navImage: UIImage {
        DecodedImages.image(navImageData) ?? frontImage
    }

    /// kg per PS.
    var powerToWeight: Double? {
        guard let powerPS, let weightKg, powerPS > 0 else { return nil }
        return Double(weightKg) / Double(powerPS)
    }
}

/// The car images, decoded once per content. Lists, the live card and
/// the navigation marker (redrawn up to 120 times a second) ask for them
/// constantly; decoding the PNG every time cost real frame time.
private enum DecodedImages {
    nonisolated(unsafe) static let cache = NSCache<NSData, UIImage>()

    static func image(_ data: Data?) -> UIImage? {
        guard let data else { return nil }
        let key = data as NSData
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

