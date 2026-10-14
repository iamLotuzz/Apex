import Foundation
import SwiftData
import UIKit
import WidgetKit

@MainActor
enum Persistence {
    static let container: ModelContainer = {
        let schema = Schema([Drive.self, Track.self, TrackSession.self, Car.self])
        let configuration = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("SwiftData container failed: \(error)")
        }
    }()

    static var context: ModelContext { container.mainContext }

    static func save() {
        try? context.save()
    }

    static func activeCar() -> Car? {
        let descriptor = FetchDescriptor<Car>(sortBy: [SortDescriptor(\.createdAt)])
        let cars = (try? context.fetch(descriptor)) ?? []
        return cars.first(where: \.isActive) ?? cars.first
    }

    /// Creates the first car on a fresh install.
    static func ensureCar() {
        let descriptor = FetchDescriptor<Car>()
        let count = (try? context.fetchCount(descriptor)) ?? 0
        guard count == 0 else { return }
        let car = Car()
        car.isActive = true
        context.insert(car)
        save()
        syncActiveCarToWidget()
    }

    static func setActive(_ car: Car) {
        let all = (try? context.fetch(FetchDescriptor<Car>())) ?? []
        for other in all { other.isActive = (other.id == car.id) }
        save()
        syncActiveCarToWidget()
    }

    /// Copies the active car's front image, name and fuel type into the App Group.
    static func syncActiveCarToWidget() {
        guard let car = activeCar() else { return }
        SharedStore.saveCarImage(WidgetImage.pngData(for: car.frontImage))
        SharedStore.carName = car.displayName
        SharedStore.fuelType = car.fuelType
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func deleteAllDrives() {
        let drives = (try? context.fetch(FetchDescriptor<Drive>())) ?? []
        for drive in drives { context.delete(drive) }
        save()
        MapSnapshotCache.shared.removeAll()
    }
}

/// Keeps the widget copy of the car small: widgets have a tight memory limit.
enum WidgetImage {
    static func pngData(for image: UIImage, maxSide: CGFloat = 240) -> Data? {
        let size = image.size
        let scale = image.scale
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxSide else { return image.pngData() }
        let factor = maxSide / longest
        let target = CGSize(width: max(1, (pixelWidth * factor).rounded()), height: max(1, (pixelHeight * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { ctx in
            ctx.cgContext.interpolationQuality = .none
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.pngData()
    }
}
