import UIKit
import SwiftUI

/// The built-in pixel cars, used until the user adds their own PNGs:
/// a side view for driving scenes and a front three-quarter view for
/// widgets and icons.
enum DefaultPixelCar {
    /// Side view, front to the right.
    static let rows: [String] = [
        "...............kkkkkkkkkk...............",
        ".............kkwwwwwkwwwwkk.............",
        "...........kkwwwwwwwkwwwwwwkk...........",
        ".........kkbwwwwwwwwkwwwwwwwwkkk........",
        "......kkkbbbbbbbbbbbkbbbbbbbbbbbbkkkkk..",
        "...kkkllllllllllllllllllllllllllllllllk.",
        "..kolbbbkkkkkkbbbbbbbbbbbbbbbkkkkkkbbbyk",
        "..kobbbkkttttkkbbbbbbbbbbbbbkkttttkkbbbk",
        "..kbbbbkttttttkbbbbbbbbbbbbbkttttttkbbbk",
        "...kdddttrrrrttdddddddddddddttrrrrttdddk",
        "....kkkttrhhrttkkkkkkkkkkkkkttrhhrttkkk.",
        ".......ttrhhrtt.............ttrhhrtt....",
        "........ttrrtt...............ttrrtt.....",
        ".........tttt.................tttt......"
    ]

    static let palette: [Character: UInt32] = [
        "k": 0x15171D, "b": 0xE5432B, "d": 0xA3281A, "l": 0xFF7B5E,
        "w": 0xA7D8F2, "v": 0x5B8FBF, "t": 0x25272E, "r": 0xC3C9D3,
        "h": 0x6E7582, "y": 0xFFE07A, "o": 0xFF2D55, "g": 0x3A3D45,
        "p": 0xF2F2F2
    ]

    /// Front three-quarter view.
    static let frontRows: [String] = [
        "........kkkkkkkkkkkkk..............",
        ".......kwwwwwwwwwwwwwkkkkkkkk.......",
        "......kwwwwwwwwwwwwwwwkvvvvvvkk.....",
        ".....kwwwwwwwwwwwwwwwwwkvvvvvvvkk...",
        "...kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk..",
        "..kklllllllllllllllllllllkbbbbbbbbk.",
        "..kbbbbbbbbbbbbbbbbbbbbbbkdddddddddk",
        "..kyyyybbbbbbbbbbbbbbyyyykdddddddddk",
        "..kyyyykkkkkkkkkkkkkkyyyykdddddddddk",
        "..kbbbbkgkgkgkgkgkgkkbbbbkdddkkkkddk",
        "..kbbbbkkkkkkkkkkkkkkbbbbkddkttttkdk.",
        "..kddddddddpppppddddddddkkkkttttkkk..",
        "..kkkkkkkkkkkkkkkkkkkkkkk..ktrrtk....",
        "..ktrtk...........ktrtk....ktrrtk....",
        "..ktrtk...........ktrtk.....kkkk.....",
        "...kkk.............kkk.............."
    ]

    /// Side view, one image point per pixel. Draw it with `.interpolation(.none)`.
    static let image: UIImage = render(rows: rows, palette: palette)

    /// Front three-quarter view for widgets and icons.
    static let frontImage: UIImage = render(rows: frontRows, palette: palette)

    static var pngData: Data? { image.pngData() }

    static func render(rows: [String], palette: [Character: UInt32]) -> UIImage {
        let width = rows.map(\.count).max() ?? 1
        let height = rows.count
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { ctx in
            for (y, row) in rows.enumerated() {
                for (x, char) in row.enumerated() {
                    guard let hex = palette[char] else { continue }
                    UIColor(hex: hex).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Shows a pixel image crisp at any size.
struct PixelImage: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.none)
            .antialiased(false)
            .aspectRatio(contentMode: .fit)
    }
}

/// A fuel price in the German price-board style: "1,72⁹".
struct PriceText: View {
    let price: Double
    var size: CGFloat = 17
    var weight: Font.Weight = .bold

    var body: some View {
        let parts = PriceFormat.parts(price)
        HStack(alignment: .top, spacing: 0) {
            Text(parts.main)
                .font(.system(size: size, weight: weight, design: .rounded))
            Text(parts.last)
                .font(.system(size: size * 0.55, weight: weight, design: .rounded))
                .padding(.top, size * 0.02)
        }
        .monospacedDigit()
    }
}
