import SwiftUI

enum Fmt {
    static var decimalSeparator: String { Locale.current.decimalSeparator ?? "," }

    static func number(_ value: Double, digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// "850 m" or "12,3 km".
    static func distance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        let digits = meters < 100_000 ? 1 : 0
        return "\(number(meters / 1000, digits: digits)) km"
    }

    static func km(_ meters: Double, digits: Int = 1) -> String {
        number(meters / 1000, digits: digits)
    }

    static func kmh(_ metersPerSecond: Double) -> String {
        "\(Int((metersPerSecond * 3.6).rounded())) km/h"
    }

    static func kmhValue(_ metersPerSecond: Double) -> String {
        "\(Int((metersPerSecond * 3.6).rounded()))"
    }

    /// "1 h 05 min", "12 min", "45 s".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(String(format: "%02d", m)) min" }
        if m > 0 { return "\(m) min" }
        return "\(total) s"
    }

    /// "1:05:12" or "12:05".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))" }
        return "\(m):\(String(format: "%02d", s))"
    }

    /// Lap time "1:23,456" or "43,210".
    static func lap(_ seconds: Double, digits: Int = 3) -> String {
        let factor = digits == 3 ? 1000.0 : (digits == 2 ? 100.0 : 10.0)
        let units = Int((max(0, seconds) * factor).rounded())
        let perMinute = Int(60 * factor)
        let minutes = units / perMinute
        let rest = units % perMinute
        let secs = rest / Int(factor)
        let fraction = rest % Int(factor)
        let fractionText = String(format: "%0\(digits)d", fraction)
        if minutes > 0 {
            return "\(minutes):\(String(format: "%02d", secs))\(decimalSeparator)\(fractionText)"
        }
        return "\(secs)\(decimalSeparator)\(fractionText)"
    }

    /// "+0,42" or "−0,42" (real minus sign).
    static func delta(_ seconds: Double, digits: Int = 2) -> String {
        let value = abs(seconds)
        let text = value.formatted(.number.precision(.fractionLength(digits)))
        if value < 0.5 / pow(10, Double(digits)) { return "±\(text)" }
        return seconds < 0 ? "−\(text)" : "+\(text)"
    }

    static func g(_ metersPerSecondSquared: Double) -> String {
        "\(number(metersPerSecondSquared / 9.81, digits: 2)) g"
    }

    static func seconds(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "–" }
        return "\(number(value, digits: digits)) s"
    }

    static func euro(_ value: Double) -> String {
        value.formatted(.currency(code: "EUR"))
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

enum SpeedPalette {
    static let edges: [Double] = [0, 30, 60, 90, 120, 150]
    static let colors: [Color] = [
        Color(red: 0.35, green: 0.78, blue: 0.98),
        Color(red: 0.20, green: 0.84, blue: 0.48),
        Color(red: 1.00, green: 0.84, blue: 0.20),
        Color(red: 1.00, green: 0.58, blue: 0.10),
        Color(red: 1.00, green: 0.25, blue: 0.25),
        Color(red: 0.75, green: 0.30, blue: 1.00)
    ]

    static func bucket(kmh: Double) -> Int {
        edges.lastIndex { kmh >= $0 } ?? 0
    }

    static func color(kmh: Double) -> Color {
        colors[bucket(kmh: kmh)]
    }

    static var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}
