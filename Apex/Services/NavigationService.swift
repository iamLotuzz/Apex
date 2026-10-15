import Foundation
import MapKit
import AVFoundation
import Observation
import UIKit

/// Settings for navigation sound and the car marker.
enum NavSettings {
    static let directionsOn = "navDirectionsOn"
    static let directionsVolume = "navDirectionsVolume"
    static let rallyOn = "navRallyOn"
    static let rallyVolume = "navRallyVolume"
    static let puckStyle = "navPuckStyle"

    static var defaults: UserDefaults { SharedStore.defaults }
    static var isDirectionsOn: Bool { defaults.object(forKey: directionsOn) as? Bool ?? true }
    static var isRallyOn: Bool { defaults.object(forKey: rallyOn) as? Bool ?? true }
    static var directionsLevel: Float { Float(defaults.object(forKey: directionsVolume) as? Double ?? 1.0) }
    static var rallyLevel: Float { Float(defaults.object(forKey: rallyVolume) as? Double ?? 0.85) }
}

/// Turn-by-turn navigation on Apple's routes, with rally pace notes.
///
/// - Position: every fix runs through the GPS filter and is snapped onto
///   the route. Between fixes, `pose` is recomputed on every screen frame
///   (60 Hz) from the fix's measurement time to now with `LiveMotion`
///   (accelerometer fused with Doppler speed). So marker, camera and speed
///   move live, and the marker sits where the car is now, not where it was
///   when the (already ~0.5 s old) fix was measured. A new fix never makes
///   the marker jump: the difference is blended out within half a second.
/// - Voice: directions and rally notes are separate, each can be switched
///   off and has its own volume. Other audio is ducked only while speaking.
/// - Media: "pause" takes the audio session so Audible, Apple Music,
///   Spotify or Podcasts pause; "play" hands it back and they resume.
/// - Rerouting after three off-route fixes; traffic check every 3 minutes.
/// - Starting navigation also starts a drive recording (if none runs) and
///   ends it with the navigation.
@MainActor
@Observable
final class NavigationService: NSObject {
    static let shared = NavigationService()

    private(set) var isActive = false
    private(set) var destinationName = ""
    private(set) var destinationCoordinate: CLLocationCoordinate2D?
    private(set) var route: MKRoute?
    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    private(set) var stepIndex = 0
    private(set) var distanceToManeuver: Double = 0
    private(set) var remainingDistance: Double = 0
    private(set) var remainingTime: TimeInterval = 0
    private(set) var location: CLLocation?
    /// Live marker position, heading and speed, updated every frame.
    private(set) var pose: NavPose?
    /// Where the marker is drawn right now.
    var displayCoordinate: CLLocationCoordinate2D? { pose?.coordinate }
    private(set) var heading: Double = 0
    private(set) var speed: Double = 0
    private(set) var isRerouting = false
    private(set) var fasterRoute: MKRoute?
    private(set) var fasterRouteSaving: TimeInterval = 0
    private(set) var arrived = false
    private(set) var rallyNotes: [RallyNote] = []
    private(set) var nextRallyNote: RallyNote?
    private(set) var distanceToRallyNote: Double = 0
    private(set) var mediaPaused = false
    private(set) var updateCount = 0
    /// Short banner about the traffic on the route (cleared after ~10 s).
    private(set) var trafficNotice: TrafficNotice?
    /// The arrival time just got later: shown in red for two minutes.
    private(set) var arrivalLateUntil = Date.distantPast

    private let manager = CLLocationManager()
    private let speech = AVSpeechSynthesizer()

    @ObservationIgnored private var destination: MKMapItem?
    @ObservationIgnored private var filter = GPSFilter()
    @ObservationIgnored private var routeCumulative: [Double] = []
    @ObservationIgnored private var routeLength: Double = 0
    @ObservationIgnored private var stepStarts: [Double] = []
    @ObservationIgnored private var segmentHint = 0
    @ObservationIgnored private var traveled: Double = 0
    @ObservationIgnored private var offRouteCount = 0
    @ObservationIgnored private var lastReroute = Date.distantPast
    @ObservationIgnored private var lastTrafficCheck = Date()
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var announcedNotes: Set<Int> = []
    @ObservationIgnored private var startedDrive = false
    @ObservationIgnored private var speaking = 0
    @ObservationIgnored private var sessionActive = false
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    // Traffic
    /// Seconds per metre for the rest of the route, from Apple's latest
    /// traffic-aware travel time.
    @ObservationIgnored private var etaRate: Double = 0
    /// Arrival time last told to the driver; delays are measured against it.
    @ObservationIgnored private var announcedArrival = Date()
    /// Cells (~45 m) the current route passes through, to tell whether a
    /// freshly calculated route is the same road or a real alternative.
    @ObservationIgnored private var routeCells: Set<Int64> = []
    @ObservationIgnored private var speedHistory: [(t: TimeInterval, v: Double)] = []
    @ObservationIgnored private var jamAnnounced = false
    @ObservationIgnored private var lastJamAnnouncement = Date.distantPast
    @ObservationIgnored private var lastWeatherCheck = Date.distantPast
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    // Live pose between fixes
    @ObservationIgnored private let live = LiveMotion()
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var fixOnRoute = false
    @ObservationIgnored private var fixAlong: Double = 0
    @ObservationIgnored private var fixPoint: CLLocationCoordinate2D?
    @ObservationIgnored private var fixCourse: Double = 0
    @ObservationIgnored private var alongCorrection: Double = 0
    @ObservationIgnored private var offsetCorrection = Vec2(x: 0, y: 0)
    @ObservationIgnored private var correctionTime = Date()
    @ObservationIgnored private var lastAlong: Double = 0
    @ObservationIgnored private var smoothHeading: Double?
    @ObservationIgnored private var lastFrame = Date()

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
        await calculateRoutes(from: coordinate, alternatives: false).first
    }

    /// Routes from `coordinate` with the current traffic (departure now).
    private func calculateRoutes(from coordinate: CLLocationCoordinate2D, alternatives: Bool) async -> [MKRoute] {
        guard let destination else { return [] }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = alternatives
        request.departureDate = Date()
        return (try? await MKDirections(request: request).calculate().routes) ?? []
    }

    // MARK: Start / stop

    /// Fastest route to `item`, started right away in Apex.
    @discardableResult
    func navigate(to item: MKMapItem) async -> Bool {
        guard let route = await routes(to: item).first else { return false }
        if isActive { stop() }
        start(route: route, to: item)
        return true
    }

    func start(route: MKRoute, to item: MKMapItem) {
        destination = item
        destinationName = item.name ?? "Ziel"
        destinationCoordinate = item.placemark.coordinate
        filter = GPSFilter()
        SpeedLimitService.shared.reset()
        apply(route)
        arrived = false
        isActive = true
        lastTrafficCheck = Date()
        announcedArrival = Date().addingTimeInterval(route.expectedTravelTime)
        arrivalLateUntil = .distantPast
        trafficNotice = nil
        speedHistory = []
        jamAnnounced = false
        lastWeatherCheck = .distantPast

        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if modes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        UIApplication.shared.isIdleTimerDisabled = true
        startLivePose()

        let location = LocationService.shared
        startedDrive = false
        if !location.isRecording && location.mode != .session {
            location.startManualDrive()
            startedDrive = location.isRecording
        }

        speakDirection("Route nach \(destinationName). Etwa \(SpeechText.duration(route.expectedTravelTime)), \(SpeechText.distance(route.distance)).")
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        manager.stopUpdatingLocation()
        speech.stopSpeaking(at: .immediate)
        if mediaPaused { resumeMedia() }
        UIApplication.shared.isIdleTimerDisabled = false
        route = nil
        routeCoordinates = []
        rallyNotes = []
        nextRallyNote = nil
        fasterRoute = nil
        trafficNotice = nil
        noticeTask?.cancel()
        SpeedLimitService.shared.reset()
        stopLivePose()
        if startedDrive && LocationService.shared.isRecording {
            LocationService.shared.stopDrive()
        }
        startedDrive = false
    }

    func acceptFasterRoute() {
        guard let faster = fasterRoute else { return }
        apply(faster)
        announcedArrival = Date().addingTimeInterval(faster.expectedTravelTime)
        speakDirection("Neue Route übernommen.")
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
        announcedNotes = []
        offRouteCount = 0
        fasterRoute = nil
        // New geometry: distances along the old route no longer apply.
        fixOnRoute = false
        lastAlong = 0
        alongCorrection = 0
        remainingDistance = routeLength
        remainingTime = route.expectedTravelTime
        etaRate = routeLength > 0 ? route.expectedTravelTime / routeLength : 0
        distanceToManeuver = stepStarts.indices.contains(stepIndex) ? stepStarts[stepIndex] : routeLength
        rallyNotes = RallyNoteBuilder.notes(coordinates: coordinates, cumulative: cumulative, maneuvers: Array(starts.dropFirst()))
        nextRallyNote = rallyNotes.first
        routeCells = Self.cells(along: coordinates, cumulative: cumulative)
        // Speed limits for the whole route, loaded ahead.
        SpeedLimitService.shared.prefetch(route: coordinates)
    }

    // MARK: Traffic

    private static func cellKey(_ c: CLLocationCoordinate2D) -> (Int, Int) {
        (Int((c.latitude / 0.0004).rounded(.down)), Int((c.longitude / 0.0006).rounded(.down)))
    }

    private static func packed(_ row: Int, _ col: Int) -> Int64 {
        Int64(row) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: col)))
    }

    /// Every ~20 m of the route as a grid cell.
    private static func cells(along coordinates: [CLLocationCoordinate2D], cumulative: [Double]) -> Set<Int64> {
        var cells: Set<Int64> = []
        guard coordinates.count >= 2 else { return cells }
        for i in 1..<coordinates.count {
            let a = coordinates[i - 1]
            let b = coordinates[i]
            let steps = max(1, Int((cumulative[i] - cumulative[i - 1]) / 20))
            for s in 0...steps {
                let f = Double(s) / Double(steps)
                let c = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                               longitude: a.longitude + (b.longitude - a.longitude) * f)
                let (row, col) = cellKey(c)
                cells.insert(packed(row, col))
            }
        }
        return cells
    }

    /// True when `candidate` drives the same roads as the current route
    /// (checked on its first 20 km, every ~200 m).
    private func followsCurrentRoute(_ candidate: MKRoute) -> Bool {
        let coordinates = candidate.polyline.coordinateList
        guard coordinates.count >= 2 else { return false }
        var checked = 0
        var hits = 0
        var travelled = 0.0
        var nextSample = 300.0
        for i in 1..<coordinates.count {
            travelled += Geo.distance(coordinates[i - 1], coordinates[i])
            guard travelled >= nextSample else { continue }
            nextSample += 200
            if travelled > 20_000 { break }
            checked += 1
            let (row, col) = Self.cellKey(coordinates[i])
            var near = false
            for dr in -1...1 where !near {
                for dc in -1...1 where routeCells.contains(Self.packed(row + dr, col + dc)) {
                    near = true
                }
            }
            if near { hits += 1 }
        }
        return checked == 0 || Double(hits) / Double(checked) >= 0.85
    }

    /// Every 2 minutes: fresh traffic-aware travel time for the rest of the
    /// route (so the arrival time stays true), a spoken note when it gets
    /// 5 minutes later or earlier, and a faster alternative when there is a
    /// real one (different roads, at least 3 minutes quicker).
    private func checkTraffic() {
        refreshWeather()
        guard Date().timeIntervalSince(lastTrafficCheck) > 120, !arrived, !isRerouting,
              let here = displayCoordinate else { return }
        lastTrafficCheck = Date()
        Task {
            let candidates = await calculateRoutes(from: here, alternatives: true)
            guard isActive, !candidates.isEmpty else { return }
            let same = candidates.first { followsCurrentRoute($0) }
            if let same, same.distance > 0 {
                etaRate = same.expectedTravelTime / same.distance
                remainingTime = remainingDistance * etaRate
                reportArrivalChange()
            }
            let current = same?.expectedTravelTime ?? remainingTime
            if fasterRoute == nil,
               let best = candidates.filter({ !followsCurrentRoute($0) }).min(by: { $0.expectedTravelTime < $1.expectedTravelTime }),
               current - best.expectedTravelTime >= 180 {
                fasterRoute = best
                fasterRouteSaving = current - best.expectedTravelTime
                speakDirection("Schnellere Route gefunden, \(SpeechText.duration(fasterRouteSaving)) schneller.")
            }
        }
    }

    private func reportArrivalChange() {
        let arrival = Date().addingTimeInterval(remainingTime)
        let change = arrival.timeIntervalSince(announcedArrival)
        if change >= 300 {
            announcedArrival = arrival
            arrivalLateUntil = Date().addingTimeInterval(120)
            show(.delay(minutes: Int((change / 60).rounded()), arrival: arrival))
            speakDirection("Verzögerung von \(SpeechText.duration(change)) auf deiner Route. Ankunft um \(Self.spokenTime(arrival)).")
        } else if change <= -300 {
            announcedArrival = arrival
            show(.cleared(minutes: Int((-change / 60).rounded()), arrival: arrival))
            speakDirection("Der Verkehr hat sich aufgelöst. Ankunft jetzt um \(Self.spokenTime(arrival)).")
        }
    }

    /// "18 Uhr 24", "9 Uhr".
    private static func spokenTime(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return minute == 0 ? "\(hour) Uhr" : "\(hour) Uhr \(minute)"
    }

    private func show(_ notice: TrafficNotice) {
        trafficNotice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.trafficNotice = nil
        }
    }

    /// Slow traffic from the car's own speed: on fast roads, when the last
    /// 20 s average far below the limit after normal flow before. Works
    /// without any traffic data from Apple.
    private func detectSlowTraffic(_ fix: CLLocation) {
        guard fix.speed >= 0 else { return }
        let t = fix.timestamp.timeIntervalSinceReferenceDate
        speedHistory.append((t, fix.speed))
        speedHistory.removeAll { $0.t < t - 120 }

        let limits = SpeedLimitService.shared
        let fastRoad = ["motorway", "trunk", "primary", "motorway_link", "trunk_link"].contains(limits.roadClass ?? "")
        guard let limit = limits.limit, fastRoad || limit >= 70 else { return }
        let expected = (limit == 0 ? 120 : Double(limit)) / 3.6

        func average(_ from: Double, _ to: Double) -> Double? {
            let values = speedHistory.filter { $0.t >= t - from && $0.t <= t - to }.map(\.v)
            guard values.count >= 5 else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
        guard let recent = average(20, 0) else { return }

        if jamAnnounced {
            if recent > expected * 0.6 { jamAnnounced = false }
            return
        }
        guard let before = average(100, 30),
              recent < max(25 / 3.6, expected * 0.4), before > expected * 0.65,
              distanceToManeuver > 300, remainingDistance > 800,
              Date().timeIntervalSince(lastJamAnnouncement) > 180 else { return }
        jamAnnounced = true
        lastJamAnnouncement = Date()
        show(.slowTraffic)
        speakDirection("Achtung, stockender Verkehr.")
    }

    /// For "80 bei Nässe" signs: rain or snow at the car's position.
    private func refreshWeather() {
        guard Date().timeIntervalSince(lastWeatherCheck) > 900, let here = displayCoordinate else { return }
        lastWeatherCheck = Date()
        Task {
            guard let weather = try? await WeatherService.fetch(here) else { return }
            let condition = weather.condition
            SpeedLimitService.shared.roadIsWet = condition.isRain || condition.isSnow || weather.precipitation > 0.1
        }
    }

    // MARK: Fixes

    fileprivate func process(_ fix: CLLocation) {
        guard isActive, fix.horizontalAccuracy >= 0, route != nil else { return }
        location = fix
        speed = max(0, fix.speed)
        if fix.speed >= 0 && fix.horizontalAccuracy <= GPSFilter.maxAccuracy {
            live.fix(time: fix.timestamp, speed: fix.speed, speedAccuracy: fix.speedAccuracy)
        }
        guard let cleaned = filter.process(fix), routeCoordinates.count >= 2 else {
            updateCount += 1
            return
        }

        if let match = matchToRoute(cleaned) {
            // Where the marker is now, before the new fix moves the anchor.
            let shownBefore = pose
            let wasOnRoute = fixOnRoute
            if match.distance > max(30, fix.horizontalAccuracy * 1.5) {
                offRouteCount += 1
                if offRouteCount >= 3 { reroute(from: cleaned) }
                if fix.course >= 0 && fix.speed > 1.5 { heading = fix.course }
                fixOnRoute = false
                fixPoint = cleaned
                fixCourse = heading
            } else {
                offRouteCount = 0
                if match.along >= traveled - 30 { traveled = match.along }
                heading = match.bearing
                fixOnRoute = true
                fixAlong = traveled
                fixPoint = cleaned
            }
            anchorCorrection(previous: shownBefore, wasOnRoute: wasOnRoute)
        }

        remainingDistance = max(0, routeLength - traveled)
        remainingTime = remainingDistance * etaRate

        var next = stepIndex
        while next < stepStarts.count - 1 && stepStarts[next] < traveled - 5 {
            next += 1
        }
        if next != stepIndex { stepIndex = next }
        distanceToManeuver = max(0, (stepStarts.indices.contains(stepIndex) ? stepStarts[stepIndex] : routeLength) - traveled)

        updateRallyNotes()
        announceDirections()
        SpeedLimitService.shared.update(location: fix, heading: heading)
        detectSlowTraffic(fix)

        if remainingDistance < 35 && !arrived {
            arrived = true
            speakDirection("Du hast dein Ziel erreicht.")
        }
        checkTraffic()
        updateCount += 1
    }

    private func coordinate(atAlong distance: Double) -> CLLocationCoordinate2D? {
        guard routeCoordinates.count >= 2 else { return nil }
        var low = 0
        var high = routeCumulative.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if routeCumulative[mid] <= distance { low = mid } else { high = mid }
        }
        let span = routeCumulative[high] - routeCumulative[low]
        let f = span > 0 ? (distance - routeCumulative[low]) / span : 0
        let a = routeCoordinates[low]
        let b = routeCoordinates[high]
        return CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * f,
            longitude: a.longitude + (b.longitude - a.longitude) * f
        )
    }

    // MARK: Live pose

    private func startLivePose() {
        live.start()
        pose = nil
        fixPoint = nil
        fixOnRoute = false
        smoothHeading = nil
        lastAlong = 0
        alongCorrection = 0
        offsetCorrection = Vec2(x: 0, y: 0)
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        // ProMotion (iPhone 13 Pro and later) runs at up to 120 Hz.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLivePose() {
        displayLink?.invalidate()
        displayLink = nil
        live.stop()
        pose = nil
        fixPoint = nil
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        updatePose(at: Date())
    }

    /// Unblended marker position for `now`, from the last fix forward.
    private func rawPosition(at now: Date) -> (along: Double?, coordinate: CLLocationCoordinate2D, course: Double)? {
        if fixOnRoute, routeCoordinates.count >= 2 {
            // On the route the road gives the shape, so only the distance is
            // integrated; it keeps going through tunnels (no fixes).
            let driven = live.distanceSinceFix(at: now, coast: true)
            let along = min(routeLength, fixAlong + driven)
            guard let c = coordinate(atAlong: along) else { return nil }
            return (along, c, routeBearing(at: along))
        }
        // Off the route: follow the gyroscope, so the car turns at once.
        guard let point = fixPoint else { return nil }
        let track = live.track(from: fixCourse, at: now, coast: false)
        let c = LocalProjection(origin: point).coordinate(Vec2(x: track.east, y: track.north))
        return (nil, c, track.course)
    }

    /// When a new fix moves the anchor, keep the marker where it was and
    /// blend the difference out over the next half second.
    private func anchorCorrection(previous: NavPose?, wasOnRoute: Bool) {
        let now = Date()
        correctionTime = now
        guard let previous, let raw = rawPosition(at: now) else {
            alongCorrection = 0
            offsetCorrection = Vec2(x: 0, y: 0)
            return
        }
        if fixOnRoute && wasOnRoute, let along = raw.along {
            let difference = previous.along - along
            alongCorrection = abs(difference) < 60 ? difference : 0
            if alongCorrection == 0 { lastAlong = along }
            offsetCorrection = Vec2(x: 0, y: 0)
        } else {
            let projection = LocalProjection(origin: raw.coordinate)
            let difference = projection.point(previous.coordinate)
            offsetCorrection = difference.length < 60 ? difference : Vec2(x: 0, y: 0)
            alongCorrection = 0
            if let along = raw.along { lastAlong = along }
        }
    }

    private func updatePose(at now: Date) {
        guard isActive, let raw = rawPosition(at: now) else { return }
        let decay = exp(-now.timeIntervalSince(correctionTime) / 0.45)
        let liveSpeed = live.speed(at: now)
        var coordinate = raw.coordinate
        var course = raw.course
        var along = lastAlong

        if let rawAlong = raw.along {
            along = min(routeLength, max(0, rawAlong + alongCorrection * decay))
            // Never roll backwards while driving.
            if liveSpeed > 0.5 { along = max(along, lastAlong) }
            lastAlong = along
            coordinate = self.coordinate(atAlong: along) ?? coordinate
            course = routeBearing(at: along)
        }
        if offsetCorrection.length > 0.01 {
            let projection = LocalProjection(origin: coordinate)
            coordinate = projection.coordinate(offsetCorrection * decay)
        }

        // Turn smoothly instead of snapping at every polyline vertex.
        let dt = min(0.1, max(0, now.timeIntervalSince(lastFrame)))
        lastFrame = now
        if let current = smoothHeading {
            var delta = (course - current).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            var next = current + delta * (1 - exp(-dt / 0.22))
            if next < 0 { next += 360 }
            if next >= 360 { next -= 360 }
            smoothHeading = next
        } else {
            smoothHeading = course
        }

        let toManeuver = max(0, (stepStarts.indices.contains(stepIndex) ? stepStarts[stepIndex] : routeLength) - along)
        pose = NavPose(
            coordinate: coordinate,
            heading: smoothHeading ?? course,
            speed: liveSpeed,
            along: along,
            distanceToManeuver: fixOnRoute ? toManeuver : distanceToManeuver,
            remainingDistance: fixOnRoute ? max(0, routeLength - along) : remainingDistance
        )
    }

    /// Direction of the route around a point, looking slightly ahead.
    private func routeBearing(at along: Double) -> Double {
        guard let a = coordinate(atAlong: max(0, along - 6)),
              let b = coordinate(atAlong: min(routeLength, along + 14)) else { return heading }
        let p = LocalProjection(origin: a).point(b)
        guard p.length > 0.5 else { return heading }
        var bearing = atan2(p.x, p.y) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return bearing
    }

    static func offset(_ c: CLLocationCoordinate2D, heading: Double, meters: Double) -> CLLocationCoordinate2D {
        let radians = heading * .pi / 180
        return CLLocationCoordinate2D(
            latitude: c.latitude + cos(radians) * meters / 111_320,
            longitude: c.longitude + sin(radians) * meters / (111_320 * cos(c.latitude * .pi / 180))
        )
    }

    private func matchToRoute(_ c: CLLocationCoordinate2D) -> (along: Double, distance: Double, bearing: Double)? {
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
        let along = routeCumulative[match.index] + (routeCumulative[match.index + 1] - routeCumulative[match.index]) * match.u
        let segment = LocalProjection(origin: routeCoordinates[match.index]).point(routeCoordinates[match.index + 1])
        var bearing = atan2(segment.x, segment.y) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return (along, match.distance, bearing)
    }

    private func reroute(from coordinate: CLLocationCoordinate2D) {
        guard !isRerouting, Date().timeIntervalSince(lastReroute) > 8 else { return }
        isRerouting = true
        lastReroute = Date()
        Task {
            if let newRoute = await calculateRoute(from: coordinate) {
                apply(newRoute)
                speakDirection("Neue Route.")
            }
            isRerouting = false
            offRouteCount = 0
        }
    }


    // MARK: Rally notes

    private func updateRallyNotes() {
        let upcoming = rallyNotes.first { $0.end > traveled }
        nextRallyNote = upcoming
        distanceToRallyNote = max(0, (upcoming?.along ?? routeLength) - traveled)
        guard NavSettings.isRallyOn, let note = upcoming, !announcedNotes.contains(note.id) else { return }
        // Call the corner about 6 seconds ahead (at least 70 m), like a co-driver.
        let lead = max(70, speed * 6)
        guard distanceToRallyNote <= lead else { return }
        // Already halfway through: too late to be useful.
        if traveled > note.along + (note.end - note.along) * 0.5 {
            announcedNotes.insert(note.id)
            return
        }
        // Every corner is called, also at junctions. While a direction is
        // being spoken the call waits, as long as there is time, so both
        // are heard in full instead of overlapping.
        if speaking > 0 && distanceToRallyNote > max(25, speed * 2.5) { return }

        var text = note.spoken
        announcedNotes.insert(note.id)
        // Link the following corners: "in" (under 30 m), "und" (under 100 m).
        var current = note
        var chained = 0
        while chained < 2, let index = rallyNotes.firstIndex(of: current), rallyNotes.indices.contains(index + 1) {
            let following = rallyNotes[index + 1]
            let gap = following.along - current.end
            if gap < 30 {
                text += " in " + following.spoken
            } else if gap < 100 {
                text += ", und " + following.spoken
            } else {
                break
            }
            announcedNotes.insert(following.id)
            current = following
            chained += 1
        }
        // Then the straight after it, so the next call is expected: "… 200".
        if let index = rallyNotes.firstIndex(of: current) {
            let next = rallyNotes.indices.contains(index + 1) ? rallyNotes[index + 1].along : routeLength
            let straight = next - current.end
            if straight >= 1000 {
                text += ", lange Gerade"
            } else if straight >= 150 {
                text += ", \(Int((straight / 50).rounded() * 50))"
            }
        }
        speak(text, volume: NavSettings.rallyLevel, rate: 0.53)
    }

    // MARK: Directions

    private func announceDirections() {
        guard NavSettings.isDirectionsOn, let route, route.steps.indices.contains(stepIndex) else { return }
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
            var text = instruction
            // Two turns close together are said in one go, like Apple Maps.
            if route.steps.indices.contains(stepIndex + 1) {
                let then = route.steps[stepIndex + 1]
                if then.distance < 150 && !then.instructions.isEmpty {
                    text += ", dann " + SpeechText.continuing(then.instructions)
                }
            }
            speakDirection(text, urgent: true)
        } else if d <= soon {
            guard !announced.contains(key + "s") else { return }
            announced.formUnion([key + "s", key + "p"])
            speakDirection("In \(SpeechText.inDistance(d)) \(SpeechText.continuing(instruction))")
        } else if d <= prepare && legLength > prepare + 200 {
            guard !announced.contains(key + "p") else { return }
            announced.insert(key + "p")
            speakDirection("In \(SpeechText.inDistance(d)) \(SpeechText.continuing(instruction))")
        }
    }

    /// `urgent`: the turn is right ahead, so a rally call that is still
    /// talking stops at the next word instead of delaying the instruction.
    private func speakDirection(_ text: String, urgent: Bool = false) {
        guard NavSettings.isDirectionsOn else { return }
        if urgent && speech.isSpeaking {
            speech.stopSpeaking(at: .word)
            speaking = 0
        }
        speak(text, volume: NavSettings.directionsLevel, rate: AVSpeechUtteranceDefaultSpeechRate)
    }

    // MARK: Audio

    /// One audio session for the whole stretch of speech.
    ///
    /// Activating the session starts ducking other audio, which takes a
    /// moment; speech that starts at the same time loses its first syllable.
    /// So the first utterance waits briefly, and the session stays active
    /// for a second after the last one, so back-to-back announcements do not
    /// make the music pump up and down.
    private func speak(_ text: String, volume: Float, rate: Float) {
        guard volume > 0.01 else { return }
        let session = AVAudioSession.sharedInstance()
        if mediaPaused {
            try? session.setCategory(.playback, mode: .voicePrompt, options: [])
        } else {
            try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        }
        let wasActive = sessionActive
        if !sessionActive {
            try? session.setActive(true)
            sessionActive = true
        }
        releaseTask?.cancel()

        let utterance = AVSpeechUtterance(string: SpeechText.normalize(text))
        utterance.voice = Self.voice
        utterance.rate = rate
        utterance.volume = volume
        utterance.pitchMultiplier = 1.0
        utterance.prefersAssistiveTechnologySettings = false
        utterance.preUtteranceDelay = wasActive ? 0 : 0.2
        utterance.postUtteranceDelay = 0.05
        speaking += 1
        speech.speak(utterance)
    }

    fileprivate func utteranceFinished() {
        speaking = max(0, speaking - 1)
        guard speaking == 0, !mediaPaused else { return }
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled, self.speaking == 0, !self.speech.isSpeaking, !self.mediaPaused else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.sessionActive = false
        }
    }

    /// Takes the audio session without mixing: other apps' playback pauses.
    func pauseMedia() {
        let session = AVAudioSession.sharedInstance()
        releaseTask?.cancel()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        sessionActive = true
        mediaPaused = true
    }

    /// Hands the session back; Audible, Music, Spotify etc. resume.
    func resumeMedia() {
        mediaPaused = false
        guard speaking == 0 else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    func toggleMedia() {
        if mediaPaused { resumeMedia() } else { pauseMedia() }
    }

    func testVoice(rally: Bool) {
        if rally {
            speak("Rechts vier in Links drei, und Haarnadel rechts, 200", volume: NavSettings.rallyLevel, rate: 0.53)
        } else {
            speak("In 300 Metern rechts abbiegen auf die Hauptstr., dann links auf die B258", volume: NavSettings.directionsLevel, rate: AVSpeechUtteranceDefaultSpeechRate)
        }
    }

    /// Best installed German voice: Premium, then Enhanced, then the default.
    private static var voice: AVSpeechSynthesisVoice? {
        let german = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "de-DE" }
        return german.first { $0.quality == .premium }
            ?? german.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    /// Name and quality of the voice in use, for the sound settings.
    static var voiceDescription: (name: String, isHighQuality: Bool) {
        guard let voice else { return ("Standard", false) }
        return (voice.name, voice.quality == .premium || voice.quality == .enhanced)
    }

    static func displayDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return "\((meters / 1000).formatted(.number.precision(.fractionLength(meters >= 10_000 ? 0 : 1)))) km"
        }
        let rounded = meters >= 100 ? (meters / 50).rounded() * 50 : (meters / 10).rounded() * 10
        return "\(Int(rounded)) m"
    }

}

/// The car as drawn in this frame.
struct NavPose: Equatable {
    var coordinate: CLLocationCoordinate2D
    var heading: Double
    /// Live speed in m/s.
    var speed: Double
    var along: Double
    var distanceToManeuver: Double
    var remainingDistance: Double

    static func == (a: NavPose, b: NavPose) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
            && a.heading == b.heading && a.speed == b.speed
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
        Task { @MainActor in
            self.utteranceFinished()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.utteranceFinished()
        }
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

/// What the traffic banner says.
enum TrafficNotice: Equatable {
    case delay(minutes: Int, arrival: Date)
    case cleared(minutes: Int, arrival: Date)
    case slowTraffic
}
