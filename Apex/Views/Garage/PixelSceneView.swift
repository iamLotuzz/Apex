import SwiftUI
import UIKit

/// An animated pixel-art street scene. Sky, sun/moon, clouds, rain and snow
/// follow the live weather; the road scrolls as if the car were driving.
struct PixelSceneView: View {
    let car: UIImage
    let weather: WeatherSnapshot?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let size = geo.size
                let roadTop = size.height * 0.72
                let carWidth = min(size.width * 0.6, 300)
                let carHeight = carWidth * car.size.height / max(car.size.width, 1)
                let bounce: CGFloat = Int(t * 6) % 2 == 0 ? 0 : -2
                ZStack(alignment: .topLeading) {
                    Canvas { context, canvasSize in
                        PixelScene.draw(&context, size: canvasSize, time: t, weather: weather, roadTop: roadTop)
                    }
                    PixelImage(image: car)
                        .frame(width: carWidth, height: carHeight)
                        .position(x: size.width / 2, y: roadTop + size.height * 0.11 - carHeight / 2 + bounce)
                        .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 4)
                }
            }
        }
    }
}

enum PixelScene {
    static let p: CGFloat = 4

    static func draw(_ gc: inout GraphicsContext, size: CGSize, time t: Double, weather: WeatherSnapshot?, roadTop: CGFloat) {
        let hour = Calendar.current.component(.hour, from: Date())
        let isDay = weather?.isDay ?? (hour >= 7 && hour < 20)
        let condition = WeatherCondition(code: weather?.code ?? 0, isDay: isDay)
        let cloudy = (weather?.code ?? 0) >= 2
        let overcast = (weather?.code ?? 0) >= 3

        drawSky(&gc, size: size, isDay: isDay, overcast: overcast || condition.isRain || condition.isSnow)
        if !isDay { drawStars(&gc, size: size, t: t, roadTop: roadTop, dim: overcast) }
        if !overcast {
            if isDay { drawSun(&gc, size: size) } else { drawMoon(&gc, size: size) }
        }
        drawHills(&gc, size: size, t: t, roadTop: roadTop, isDay: isDay)
        if cloudy { drawClouds(&gc, size: size, t: t, count: overcast ? 5 : 3, isDay: isDay, dark: condition.isRain || condition.isThunder) }
        if condition.isThunder && sin(t * 1.3) > 0.985 {
            gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.55)))
        }
        drawRoad(&gc, size: size, t: t, roadTop: roadTop, isDay: isDay, wet: condition.isRain)
        if condition.isFog { drawFog(&gc, size: size, t: t) }
        if condition.isRain { drawRain(&gc, size: size, t: t, heavy: condition.isHeavyRain) }
        if condition.isSnow { drawSnow(&gc, size: size, t: t) }
    }

    // MARK: Helpers

    private static func rand(_ i: Int, _ salt: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + salt * 78.233) * 43_758.5453
        return v - floor(v)
    }

    private static func snap(_ v: CGFloat) -> CGFloat { (v / p).rounded(.down) * p }

    private static func pixel(_ gc: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
        gc.fill(Path(CGRect(x: snap(x), y: snap(y), width: w, height: h)), with: .color(color))
    }

    private static func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ f: Double) -> Color {
        Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }

    // MARK: Layers

    private static func drawSky(_ gc: inout GraphicsContext, size: CGSize, isDay: Bool, overcast: Bool) {
        let top: (Double, Double, Double)
        let bottom: (Double, Double, Double)
        switch (isDay, overcast) {
        case (true, false): top = (0.24, 0.55, 0.98); bottom = (0.70, 0.86, 1.0)
        case (true, true): top = (0.42, 0.48, 0.57); bottom = (0.70, 0.74, 0.79)
        case (false, false): top = (0.03, 0.05, 0.16); bottom = (0.20, 0.17, 0.40)
        case (false, true): top = (0.07, 0.08, 0.12); bottom = (0.20, 0.21, 0.26)
        }
        let bands = 10
        let bandHeight = ceil(size.height / CGFloat(bands) / p) * p
        for i in 0..<bands {
            let f = Double(i) / Double(bands - 1)
            gc.fill(Path(CGRect(x: 0, y: CGFloat(i) * bandHeight, width: size.width, height: bandHeight + 1)), with: .color(mix(top, bottom, f)))
        }
    }

    private static func drawStars(_ gc: inout GraphicsContext, size: CGSize, t: Double, roadTop: CGFloat, dim: Bool) {
        for i in 0..<45 {
            let x = rand(i, 1) * size.width
            let y = rand(i, 2) * roadTop * 0.7
            let twinkle = 0.5 + 0.5 * sin(t * (1 + rand(i, 3) * 2) + Double(i))
            pixel(&gc, x, y, p / 2 + 1, p / 2 + 1, .white.opacity((dim ? 0.25 : 0.85) * twinkle))
        }
    }

    private static func disc(_ gc: inout GraphicsContext, cx: CGFloat, cy: CGFloat, r: Int, color: Color) {
        for dy in -r...r {
            for dx in -r...r where dx * dx + dy * dy <= r * r {
                pixel(&gc, cx + CGFloat(dx) * p, cy + CGFloat(dy) * p, p, p, color)
            }
        }
    }

    private static func drawSun(_ gc: inout GraphicsContext, size: CGSize) {
        let cx = size.width * 0.8
        let cy = size.height * 0.2
        disc(&gc, cx: cx, cy: cy, r: 7, color: Color(red: 1, green: 0.85, blue: 0.4).opacity(0.35))
        disc(&gc, cx: cx, cy: cy, r: 5, color: Color(red: 1, green: 0.88, blue: 0.35))
    }

    private static func drawMoon(_ gc: inout GraphicsContext, size: CGSize) {
        let cx = size.width * 0.8
        let cy = size.height * 0.2
        disc(&gc, cx: cx, cy: cy, r: 5, color: Color(red: 0.95, green: 0.94, blue: 0.85))
        disc(&gc, cx: cx + 3 * p, cy: cy - 2 * p, r: 4, color: Color(red: 0.08, green: 0.09, blue: 0.22))
    }

    private static func drawHills(_ gc: inout GraphicsContext, size: CGSize, t: Double, roadTop: CGFloat, isDay: Bool) {
        let far = isDay ? Color(red: 0.42, green: 0.62, blue: 0.55) : Color(red: 0.10, green: 0.12, blue: 0.22)
        let near = isDay ? Color(red: 0.25, green: 0.50, blue: 0.33) : Color(red: 0.06, green: 0.08, blue: 0.14)
        let columns = Int(size.width / p) + 1
        for (layer, color, speed, amp, base) in [(0, far, 6.0, 0.14, 0.16), (1, near, 14.0, 0.08, 0.06)] {
            let shift = t * speed
            for c in 0..<columns {
                let x = Double(c) * Double(p) + shift
                let wave = sin(x / (layer == 0 ? 90 : 45)) * 0.5 + sin(x / (layer == 0 ? 37 : 23)) * 0.25
                let height = size.height * CGFloat(base + amp * (wave + 0.75))
                let top = snap(roadTop - height)
                gc.fill(Path(CGRect(x: CGFloat(c) * p, y: top, width: p, height: roadTop - top + 1)), with: .color(color))
            }
        }
    }

    private static func drawClouds(_ gc: inout GraphicsContext, size: CGSize, t: Double, count: Int, isDay: Bool, dark: Bool) {
        let color: Color = dark
            ? Color(red: 0.45, green: 0.48, blue: 0.53)
            : (isDay ? .white.opacity(0.92) : Color(red: 0.35, green: 0.37, blue: 0.45))
        for i in 0..<count {
            let width = size.width * (0.22 + rand(i, 5) * 0.15)
            let span = Double(size.width + width * 2)
            let x = CGFloat((rand(i, 6) * span + t * (6 + rand(i, 7) * 8)).truncatingRemainder(dividingBy: span)) - width
            let y = size.height * CGFloat(0.08 + rand(i, 8) * 0.3)
            let r = Int(width / p / 5)
            disc(&gc, cx: x + width * 0.3, cy: y, r: r, color: color)
            disc(&gc, cx: x + width * 0.55, cy: y - CGFloat(r) * p * 0.5, r: r + 1, color: color)
            disc(&gc, cx: x + width * 0.8, cy: y, r: r, color: color)
            pixel(&gc, x + width * 0.3, y, width * 0.5, CGFloat(r) * p, color)
        }
    }

    private static func drawRoad(_ gc: inout GraphicsContext, size: CGSize, t: Double, roadTop: CGFloat, isDay: Bool, wet: Bool) {
        let asphalt = isDay ? Color(red: 0.22, green: 0.23, blue: 0.27) : Color(red: 0.10, green: 0.11, blue: 0.14)
        gc.fill(Path(CGRect(x: 0, y: snap(roadTop), width: size.width, height: size.height - snap(roadTop))), with: .color(asphalt))

        // Curb: red/white blocks scrolling left.
        let block = p * 4
        let curbShift = CGFloat((t * 140).truncatingRemainder(dividingBy: Double(block * 2)))
        var x = -curbShift
        var index = 0
        while x < size.width {
            let color: Color = index % 2 == 0 ? Color(red: 0.9, green: 0.2, blue: 0.2) : .white
            gc.fill(Path(CGRect(x: x, y: snap(roadTop), width: block, height: p * 1.5)), with: .color(color))
            x += block
            index += 1
        }

        // Centre dashes.
        let dash = p * 6
        let laneY = snap(roadTop + (size.height - roadTop) * 0.62)
        let dashShift = CGFloat((t * 140).truncatingRemainder(dividingBy: Double(dash * 2)))
        var dx = -dashShift
        while dx < size.width {
            gc.fill(Path(CGRect(x: dx, y: laneY, width: dash, height: p)), with: .color(.white.opacity(0.75)))
            dx += dash * 2
        }

        if wet {
            for i in 0..<6 {
                let px = CGFloat((rand(i, 11) * Double(size.width) - t * 140).truncatingRemainder(dividingBy: Double(size.width)))
                let wrapped = px < 0 ? px + size.width : px
                pixel(&gc, wrapped, roadTop + p * 3 + CGFloat(rand(i, 12)) * (size.height - roadTop - p * 6), p * 8, p, .white.opacity(0.18))
            }
        }
    }

    private static func drawRain(_ gc: inout GraphicsContext, size: CGSize, t: Double, heavy: Bool) {
        let count = heavy ? 110 : 65
        for i in 0..<count {
            let speed = 380 + rand(i, 21) * 160
            let y = CGFloat((rand(i, 22) * Double(size.height) + t * speed).truncatingRemainder(dividingBy: Double(size.height)))
            let x = CGFloat(rand(i, 23)) * size.width - y * 0.12
            pixel(&gc, x, y, p / 2 + 1, p * 3, .white.opacity(0.5))
        }
    }

    private static func drawSnow(_ gc: inout GraphicsContext, size: CGSize, t: Double) {
        for i in 0..<70 {
            let speed = 30 + rand(i, 31) * 30
            let y = CGFloat((rand(i, 32) * Double(size.height) + t * speed).truncatingRemainder(dividingBy: Double(size.height)))
            let x = CGFloat(rand(i, 33)) * size.width + CGFloat(sin(t + Double(i)) * 6)
            pixel(&gc, x, y, p, p, .white.opacity(0.9))
        }
    }

    private static func drawFog(_ gc: inout GraphicsContext, size: CGSize, t: Double) {
        for i in 0..<4 {
            let y = size.height * CGFloat(0.35 + Double(i) * 0.13)
            let shift = CGFloat((t * (8 + Double(i) * 4)).truncatingRemainder(dividingBy: Double(size.width)))
            gc.fill(Path(CGRect(x: -shift, y: snap(y), width: size.width * 2, height: p * 5)), with: .color(.white.opacity(0.22)))
        }
    }
}
