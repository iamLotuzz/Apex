import SwiftUI
import MapKit

struct DriveRow: View {
    let drive: Drive
    /// Shown only when there is more than one car.
    var car: Car? = nil

    var body: some View {
        HStack(spacing: 14) {
            RouteThumbnail(id: drive.id, pointsData: drive.pointsData)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if drive.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                    Text(drive.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if let car {
                        Spacer(minLength: 4)
                        PixelImage(image: car.frontImage)
                            .frame(width: 30, height: 18)
                            .accessibilityLabel(car.displayName)
                    }
                }
                Text("\(drive.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(Fmt.time(drive.startDate))–\(Fmt.time(drive.endDate))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    Label(Fmt.distance(drive.distance), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Label(Fmt.duration(drive.duration), systemImage: "clock")
                    Label(Fmt.kmhValue(drive.maxSpeed), systemImage: "gauge.with.dots.needle.67percent")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabelStyle())
            }
        }
        .padding(.vertical, 4)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
        .monospacedDigit()
    }
}

struct RouteThumbnail: View {
    let id: UUID
    private let loadCoordinates: () -> [CLLocationCoordinate2D]
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    init(id: UUID, pointsData: Data) {
        self.id = id
        self.loadCoordinates = { DrivePoint.decode(pointsData).map(\.coordinate) }
    }

    init(id: UUID, coordinates: [CLLocationCoordinate2D]) {
        self.id = id
        self.loadCoordinates = { coordinates }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: "map")
                        .foregroundStyle(.tertiary)
                }
            }
            .task(id: colorScheme) {
                let coords = loadCoordinates()
                let size = CGSize(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1))
                let result = await MapSnapshotCache.shared.snapshot(id: id, coordinates: coords, size: size, dark: colorScheme == .dark)
                withAnimation(.easeOut(duration: 0.2)) { image = result }
            }
        }
        .clipShape(.rect(cornerRadius: 14))
    }
}
