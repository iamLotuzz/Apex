import SwiftUI

/// A compact stat tile like in Fitness or Weather.
struct StatTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var symbol: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        // A translucent fill stays visible both on the page and inside a Card.
        .background(.fill.tertiary, in: .rect(cornerRadius: 18))
    }
}

struct StatGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            content
        }
    }
}

/// A rounded card section with a title.
struct Card<Content: View>: View {
    let title: String
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let symbol {
                Label(title, systemImage: symbol)
                    .font(.headline)
            } else {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
    }
}

/// Small value + caption pair used in glass overlays.
struct MiniStat: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
