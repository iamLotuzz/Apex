import Foundation
import MapKit
import AVFoundation
import Observation
import UIKit

/// Turn-by-turn navigation on Apple's routes.
///
/// - Map matching: every fix is snapped onto the route polyline (searched
///   near the last match, metre-accurate local projection per fix), so the
///   puck and distances follow the road instead of the GPS noise.
/// - Voice: German prompts at "prepare", "soon" and "now" distances that
///   scale with speed; other audio is ducked only while speaking.
/// - Rerouting: three fixes in a row more than ~35 m off the route trigger
///   a new route from the current position.
/// - Traffic: every three minutes Apex asks Apple for a fresh route; if it
///   saves at least three minutes, a faster route is offered.
@MainActor
@Observable
final class NavigationService: NSObject {
    static let shared = NavigationService()

    private(set) var isActive = false
    private(set) var destinationName = ""
    private(set) var destinationCoordinate: CLLocationCoordinate2D?
    private(set) var route: MKRoute?
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    /// Index into `route.steps` of the next maneuver.
    private(set) var stepIndex = 0
    private(set) var distanceToManeuver: Double = 0
    private(set) var remainingDistance: Double = 0
    private(set) var remainingTime: TimeInterval = 0
    private(set) var location: CLLocation?
    private(set) var snappedCoordinate: CLLocationCoordinate2D?
    private(set) var heading: Double = 0
    private(set) var isRerouting = false
    private(set) var fasterRoute: MKRoute?
    private(set) var fasterRouteSaving: TimeInterval = 0
    private(set) var arrived = false
    /// Increments on every processed fix; the view follows it with the camera.
    private(set) var updateCount = 0
    var voiceEnabled = true

    private let manager = CLLocationManager()
    private let speech = AVSpeechSynthesizer()

    @ObservationIgnored private var destination: MKMapItem?
    @ObservationIgnored private var routeCumulative: [Double] = []
    @ObservationIgnored private var routeLength: Double = 0
    @ObservationIgnored private var stepStarts: [Double] = []
    @ObservationIgnored private var segmentHint = 0
    @ObservationIgnored private var traveled: Double = 0
    @ObservationIgnored private var offRouteCount = 0
    @ObservationIgnored private var lastReroute = Date.distantPast
    @ObservationIgnored private var lastTrafficCheck = Date()
    @ObservationIgnored private var announced: Set<String> = []

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        speech.delegate = self
    }

    // MARK: Routes

    /// Routes for the preview, fastest first.
    func routes(to item: MKMapItem) async -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = item
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        request.departureDate = Date()
        guard let response = try? await MKDirections(request: request).calculate() else { return [] }
        return response.routes.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
    }

    private func calculateRoute(from coordinate: CLLocationCoordinate2D) async -> MKRoute? {
        guard let destination else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        request.departureDate = Date()
        return try? await MKDirections(request: request).calculate().routes.first
    }

    // MARK: Start / stop

    func start(route: MKRoute, to item: MKMapItem) {
        destination = item
        destinationName = item.name ?? "Ziel"
        destinationCoordinate = item.placemark.coordinate
        apply(route)
        arrived = false
        isActive = true
        lastTrafficCheck = Date()
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if modes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = true
        speak("Route nach \(destinationName). \(Self.spokenDuration(route.expectedTravelTime)), \(Self.spokenDistance(route.distance)).")
    }

    func stop() {
        isActive = false
        manager.stopUpdatingLocation()
        speech.stopSpeaking(at: .immediate)
        UIApplication.shared.isIdleTimerDisabled = false
        route = nil
        routeCoordinates = []
        fasterRoute = nil
        snappedCoordinate = nil
    }

    func acceptFasterRoute() {
        guard let faster = fasterRoute else { return }
        apply(faster)
        speak("Neue Route übernommen.")
    }

    func dismissFasterRoute() {
        fasterRoute = nil
    }

    private func apply(_ route: MKRoute) {
        self.route = route
        let coordinates = route.polyline.coordinateList
        routeCoordinates = coordinates
        var cumulative = [0.0]
        for i in 1..<max(coordinates.count, 1) {
            cumulative.append(cumulative[i - 1] + Geo.distance(coordinates[i - 1], coordinates[i]))
        }
        routeCumulative = cumulative
        routeLength = cumulative.last ?? 0

        // Step start positions along the polyline, scaled so they add up to its length.
        let stepTotal = route.steps.reduce(0) { $0 + $1.distance }
        let scale = stepTotal > 0 ? routeLength / stepTotal : 1
        var starts: [Double] = []
        var acc = 0.0
        for step in route.steps {
            starts.append(acc * scale)
            acc += step.distance
        }
        stepStarts = starts
        stepIndex = route.steps.count > 1 ? 1 : 0
        segmentHint = 0
        traveled = 0
        announced = []
        offRouteCount = 0
        fasterRoute = nil
        remainingDistance = routeLength
        remainingTime = route.expectedTravelTime
        distanceToManeuver = stepStarts.indices.contains(stepIndex) ? stepStarts[stepIndex] : routeLength
    }

    // MARK: Fixes

    fileprivate func process(_ fix: CLLocation) {
        guard isActive, fix.horizontalAccuracy >= 0, let route else { return }
        location = fix
        guard fix.horizontalAccuracy <= 30, routeCoordinates.count >= 2 else {
            updateCount += 1
            return
        }

        if let match = matchToRoute(fix.coordinate) {
            if match.distance > max(35, fix.horizontalAccuracy * 1.5) {
                offRouteCount += 1
                if offRouteCount >= 3 { reroute(from: fix.coordinate) }
                snappedCoordinate = fix.coordinate
                if fix.course >= 0 && fix.speed > 1.5 { heading = fix.course }
            } else {
                offRouteCount = 0
                // Never jump backwards along the route because of GPS noise.
                if match.along >= traveled - 30 { traveled = match.along }
                snappedCoordinate = match.coordinate
                heading = match.bearing
            }
        }

        remainingDistance = max(0, routeLength - traveled)
        remainingTime = routeLength > 0 ? route.expectedTravelTime * remainingDistance / routeLength : 0

        var next = stepIndex
        while next < stepStarts.count - 1 && stepStarts[next] < traveled - 5 {
            next += 1
        }
        if next != stepIndex { stepIndex = next }
        distanceToManeuver = max(0, (stepStarts.indices.contains(stepIndex) ? stepStarts[stepIndex] : routeLength) - traveled)

        announce(speed: max(0, fix.speed))

        if remainingDistance < 35 && !arrived {
            arrived = true
            speak("Du hast dein Ziel erreicht.")
        }
        checkTraffic()
        updateCount += 1
    }

    /// Nearest point on the route. Each fix gets its own local projection,
    /// so long routes stay metre-accurate.
    private func matchToRoute(_ c: CLLocationCoordinate2D) -> (along: Double, distance: Double, coordinate: CLLocationCoordinate2D, bearing: Double)? {
        let n = routeCoordinates.count
        guard n >= 2 else { return nil }
        let projection = LocalProjection(origin: c)

        func search(_ lo: Int, _ hi: Int) -> (index: Int, u: Double, distance: Double)? {
            guard lo <= hi else { return nil }
            var best: (index: Int, u: Double, distance: Double)?
            for i in lo...hi {
                let a = projection.point(routeCoordinates[i])
                let b = projection.point(routeCoordinates[i + 1])
                let ab = b - a
                let len2 = ab.dot(ab)
                let u = len2 > 0 ? min(1, max(0, (Vec2(x: 0, y: 0) - a).dot(ab) / len2)) : 0
                let d = (a + ab * u).length
                if d < (best?.distance ?? .infinity) { best = (i, u, d) }
            }
            return best
        }

        var best = search(max(0, segmentHint - 5), min(n - 2, segmentHint + 80))
        if best == nil || best!.distance > 60 {
            if let full = search(0, n - 2), full.distance < (best?.distance ?? .infinity) { best = full }
        }
        guard let match = best else { return nil }
        segmentHint = match.index
        let a = routeCoordinates[match.index]
        let b = routeCoordinates[match.index + 1]
        let along = routeCumulative[match.index] + (routeCumulative[match.index + 1] - routeCumulative[match.index]) * match.u
        let coordinate = CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * match.u,
            longitude: a.longitude + (b.longitude - a.longitude) * match.u
        )
        let segment = LocalProjection(origin: a).point(b)
        var bearing = atan2(segment.x, segment.y) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return (along, match.distance, coordinate, bearing)
    }

    private func reroute(from coordinate: CLLocationCoordinate2D) {
        guard !isRerouting, Date().timeIntervalSince(lastReroute) > 8 else { return }
        isRerouting = true
        lastReroute = Date()
        Task {
            if let newRoute = await calculateRoute(from: coordinate) {
                apply(newRoute)
                speak("Neue Route.")
            }
            isRerouting = false
            offRouteCount = 0
        }
    }

    private func checkTraffic() {
        guard Date().timeIntervalSince(lastTrafficCheck) > 180, fasterRoute == nil, let here = snappedCoordinate else { return }
        lastTrafficCheck = Date()
        let current = remainingTime
        Task {
            guard let candidate = await calculateRoute(from: here) else { return }
            let saving = current - candidate.expectedTravelTime
            if saving >= 180 {
                fasterRoute = candidate
                fasterRouteSaving = saving
                speak("Schnellere Route gefunden, \(Int((saving / 60).rounded())) Minuten schneller.")
            }
        }
    }

    // MARK: Voice

    private func announce(speed: Double) {
        guard voiceEnabled, let route, route.steps.indices.contains(stepIndex) else { return }
        let instruction = route.steps[stepIndex].instructions
        guard !instruction.isEmpty else { return }
        let d = distanceToManeuver
        let v = max(speed, 8)
        let now = max(30, v * 3)
        let soon = max(200, v * 12)
        let prepare = max(800, v * 40)
        let previousStart = stepIndex > 0 ? stepStarts[stepIndex - 1] : 0
        let legLength = (stepStarts.indices.contains(stepIndex) ? stepStarts[stepIndex] : routeLength) - previousStart
        let key = String(stepIndex)

        if d <= now {
            guard !announced.contains(key + "n") else { return }
            announced.formUnion([key + "n", key + "s", key + "p"])
            speak(instruction)
        } else if d <= soon {
            guard !announced.contains(key + "s") else { return }
            announced.formUnion([key + "s", key + "p"])
            speak("In \(Self.spokenDistance(d)) \(Self.lowercasedFirst(instruction))")
        } else if d <= prepare && legLength > prepare + 200 {
            guard !announced.contains(key + "p") else { return }
            announced.insert(key + "p")
            speak("In \(Self.spokenDistance(d)) \(Self.lowercasedFirst(instruction))")
        }
    }

    private func speak(_ text: String) {
        guard voiceEnabled else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speech.speak(utterance)
    }

    private static let voice: AVSpeechSynthesisVoice? = {
        let german = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "de-DE" }
        return german.first { $0.quality == .premium }
            ?? german.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "de-DE")
    }()

    static func spokenDistance(_ meters: Double) -> String {
        if meters >= 950 {
            let km = (meters / 100).rounded() / 10
            return km == 1 ? "1 Kilometer" : "\(km.formatted(.number.precision(.fractionLength(0...1)))) Kilometern"
        }
        let rounded = meters >= 300 ? (meters / 100).rounded() * 100 : max(50, (meters / 50).rounded() * 50)
        return "\(Int(rounded)) Metern"
    }

    static func displayDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return "\((meters / 1000).formatted(.number.precision(.fractionLength(meters >= 10_000 ? 0 : 1)))) km"
        }
        let rounded = meters >= 100 ? (meters / 50).rounded() * 50 : (meters / 10).rounded() * 10
        return "\(Int(rounded)) m"
    }

    private static func spokenDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 {
            return "\(minutes / 60) Stunden \(minutes % 60) Minuten"
        }
        return "\(minutes) Minuten"
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

extension NavigationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for fix in locations { self.process(fix) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension NavigationService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Give the volume back to music and other apps.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension MKPolyline {
    var coordinateList: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

/// SF Symbol for a German MapKit instruction.
enum ManeuverSymbol {
    static func name(for instruction: String) -> String {
        let t = instruction.lowercased()
        if t.contains("kreisverkehr") { return "arrow.triangle.turn.up.right.circle.fill" }
        if t.contains("wenden") { return "arrow.uturn.down" }
        if t.contains("ziel") || t.contains("erreicht") { return "mappin.circle.fill" }
        if t.contains("halbrechts") || t.contains("leicht rechts") || t.contains("rechts halten") || t.contains("ausfahrt") {
            return "arrow.up.right"
        }
        if t.contains("halblinks") || t.contains("leicht links") || t.contains("links halten") { return "arrow.up.left" }
        if t.contains("rechts") { return "arrow.turn.up.right" }
        if t.contains("links") { return "arrow.turn.up.left" }
        if t.contains("auffahrt") { return "arrow.up.right" }
        return "arrow.up"
    }
}
