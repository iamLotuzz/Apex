import Foundation
import MapKit
import UIKit

/// Renders small route thumbnails with MKMapSnapshotter and caches them on disk.
@MainActor
final class MapSnapshotCache {
    static let shared = MapSnapshotCache()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RouteSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `coordinates` is only called when no cached image exists, so list rows
    /// do not load a drive's whole GPS track just to show a thumbnail.
    func snapshot(id: UUID, coordinates loadCoordinates: () -> [CLLocationCoordinate2D], size: CGSize, dark: Bool) async -> UIImage? {
        let key = "\(id.uuidString)-\(dark ? "d" : "l")-\(Int(size.width))x\(Int(size.height))"
        if let cached = memory.object(forKey: key as NSString) { return cached }
        let url = directory.appendingPathComponent(key + ".png")
        let scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 3
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data, scale: scale) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        if let task = inFlight[key] { return await task.value }
        let coordinates = Geo.downsample(loadCoordinates(), maxCount: 600)
        guard coordinates.count >= 2 else { return nil }

        let task = Task { await Self.render(coordinates: coordinates, size: size, dark: dark, scale: scale) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            memory.setObject(image, forKey: key as NSString)
            try? image.pngData()?.write(to: url, options: .atomic)
        }
        return image
    }

    func remove(id: UUID) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(id.uuidString) {
            try? FileManager.default.removeItem(at: file)
        }
        memory.removeAllObjects()
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        memory.removeAllObjects()
    }

    static func mapRect(for coordinates: [CLLocationCoordinate2D], padding: Double = 0.18) -> MKMapRect {
        var rect = MKMapRect.null
        for c in coordinates {
            let p = MKMapPoint(c)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
        }
        let minSide = 1200.0
        let w = max(rect.width, minSide)
        let h = max(rect.height, minSide)
        let center = MKMapPoint(x: rect.midX, y: rect.midY)
        return MKMapRect(
            x: center.x - w * (0.5 + padding),
            y: center.y - h * (0.5 + padding),
            width: w * (1 + 2 * padding),
            height: h * (1 + 2 * padding)
        )
    }

    private static func render(coordinates: [CLLocationCoordinate2D], size: CGSize, dark: Bool, scale: CGFloat) async -> UIImage? {
        let coords = Geo.downsample(coordinates, maxCount: 400)
        let options = MKMapSnapshotter.Options()
        options.mapRect = squareish(mapRect(for: coords), aspect: size.width / max(size.height, 1))
        options.size = size
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(displayScale: scale)
        ])
        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            snapshot.image.draw(at: .zero)
            let path = UIBezierPath()
            for (i, c) in coords.enumerated() {
                let p = snapshot.point(for: c)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            UIColor.black.withAlphaComponent(dark ? 0.6 : 0.25).setStroke()
            path.lineWidth = 6
            path.stroke()
            UIColor(red: 1.0, green: 0.42, blue: 0.16, alpha: 1).setStroke()
            path.lineWidth = 3.5
            path.stroke()

            if let first = coords.first, let last = coords.last {
                drawDot(at: snapshot.point(for: first), color: .systemGreen, in: ctx.cgContext)
                drawDot(at: snapshot.point(for: last), color: .systemRed, in: ctx.cgContext)
            }
        }
    }

    private static func drawDot(at point: CGPoint, color: UIColor, in context: CGContext) {
        let rect = CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: rect.insetBy(dx: -1.5, dy: -1.5))
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)
    }

    /// Widens or heightens the rect so it matches the image aspect ratio.
    private static func squareish(_ rect: MKMapRect, aspect: Double) -> MKMapRect {
        var w = rect.width
        var h = rect.height
        if w / h > aspect { h = w / aspect } else { w = h * aspect }
        return MKMapRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}
