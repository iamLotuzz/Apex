import Foundation

enum GPXExporter {
    /// Writes the drive as a GPX 1.1 track to a temporary file and returns its URL.
    static func export(name: String, points: [DrivePoint]) -> URL? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Apex" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(escape(name))</name><trkseg>

        """
        for p in points {
            gpx += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"><ele>\(String(format: "%.1f", p.alt))</ele><time>\(iso.string(from: p.date))</time><extensions><speed>\(String(format: "%.2f", p.speed))</speed></extensions></trkpt>\n"
        }
        gpx += "</trkseg></trk>\n</gpx>\n"

        let safeName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "→", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName).gpx")
        do {
            try gpx.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
