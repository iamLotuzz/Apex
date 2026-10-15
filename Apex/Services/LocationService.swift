import Foundation
import CoreLocation
import CoreMotion
import Observation
import SwiftData
import UIKit
import UserNotifications
import WidgetKit

/// Owns the location manager. Detects drives in the background, records them,
/// and feeds track sessions.
///
/// Detection flow:
/// - idle: with "Sofort-Start" on, low-power location (cell/Wi-Fi, ~100 m)
///   keeps running, so the app stays awake and motion activity arrives live.
///   Without it, significant location changes, visits and the parking region
///   wake the app.
/// - probing: full-accuracy GPS for a short time. A fix at or above the start
///   speed (default 10 km/h) starts a drive.
/// - recording: every fix is stored. The drive gets back-dated to the moment
///   the car left its parking spot (motion history + parked position), so no
///   metres are lost. It ends after the stop timeout or when the user walks.
/// - session: a track session owns the GPS; automatic detection pauses.
@MainActor
@Observable
final class LocationService: NSObject {
    static let shared = LocationService()

    enum Mode: String {
        case idle, probing, recording, session
    }

    private(set) var mode: Mode = .idle
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastLocation: CLLocation?
    private(set) var speed: Double = 0
    private(set) var livePoints: [DrivePoint] = []
    private(set) var liveDistance: Double = 0
    private(set) var liveMaxSpeed: Double = 0
    private(set) var driveStart: Date?
    private(set) var isManualDrive = false
    private(set) var lastSavedDriveID: UUID?

    private let manager = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private let motionSensors = CMMotionManager()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var motionStarted = false
    @ObservationIgnored private var updatingLocation = false
    @ObservationIgnored private var probeStarted = Date.distantPast
    @ObservationIgnored private var probeDeadline = Date.distantPast
    @ObservationIgnored private var lastProbeEnd = Date.distantPast
    @ObservationIgnored private var recentFixes: [DrivePoint] = []
    @ObservationIgnored private var driveFilter = GPSFilter()
    /// Consecutive reliable fixes at or above the start speed while probing.
    @ObservationIgnored private var fastStreak = 0
    @ObservationIgnored private var lastMovingDate = Date()
    @ObservationIgnored private var lastAutomotiveDate = Date.distantPast
    @ObservationIgnored private var lastWalkingDate = Date.distantPast
    @ObservationIgnored private var lastPersist = Date.distantPast
    @ObservationIgnored private var lastSharedSave = Date.distantPast
    @ObservationIgnored private var wantsAlwaysUpgrade = false
    @ObservationIgnored private var sessionHandler: (@MainActor (CLLocation) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var driveTemperature: Double?
    @ObservationIgnored private var driveWeatherCode: Int?

    // Accelerometer launch detection for exact 0–100 times.
    @ObservationIgnored private var launches: [Double] = []
    @ObservationIgnored private var launchArmed = false
    @ObservationIgnored private var launchCandidate: Double?
    @ObservationIgnored private var launchSamples = 0
    /// Detected but not yet confirmed: a jolt while standing (door, phone
    /// touched) must not count. It becomes a launch when the GPS then shows
    /// the car moving within 3 s, and is dropped when it still stands.
    @ObservationIgnored private var pendingLaunch: Double?

    // Barometer: relative height to ±0.1 m instead of GPS altitude (±10 m),
    // so climbs and descents are counted correctly.
    private let altimeter = CMAltimeter()
    @ObservationIgnored private var relativeAltitude: Double?
    @ObservationIgnored private var altitudeAnchor: Double?

    /// Fixes at or above this speed count as "moving" while recording (8 km/h).
    private let movingSpeed = 2.2
    private let parkingRegionID = "apex.parking"

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    // MARK: Settings

    var autoTrackingEnabled: Bool { SharedStore.autoTracking }
    private var startSpeed: Double { SharedStore.startSpeedKmh / 3.6 }
    private var stopTimeout: TimeInterval { SharedStore.stopMinutes * 60 }

    private var lowPowerIdle: Bool {
        SharedStore.instantStart && autoTrackingEnabled && authorization == .authorizedAlways
    }

    var isRecording: Bool { mode == .recording }

    var liveDuration: TimeInterval {
        guard let driveStart else { return 0 }
        return Date().timeIntervalSince(driveStart)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if modes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
        }
        restoreActiveDrive()
        applyMonitoring()
        startMotionUpdates(force: false)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    func appBecameActive() {
        authorization = manager.authorizationStatus
        guard mode == .idle, authorization.isAuthorized else { return }
        if autoTrackingEnabled {
            startProbing(for: 60)
        } else {
            manager.requestLocation()
        }
    }

    func settingsChanged() {
        applyMonitoring()
        if !autoTrackingEnabled && mode == .probing {
            stopProbing()
        }
    }

    // MARK: Permissions

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            wantsAlwaysUpgrade = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .denied, .restricted:
            openSettings()
        default:
            break
        }
    }

    func requestMotionPermission() {
        startMotionUpdates(force: true)
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    var motionAuthorized: Bool {
        CMMotionActivityManager.authorizationStatus() == .authorized
    }

    // MARK: Manual control

    func startManualDrive() {
        guard authorization.isAuthorized else {
            requestPermission()
            return
        }
        switch mode {
        case .session:
            return
        case .recording:
            isManualDrive = true
        case .idle, .probing:
            beginDrive(manual: true)
        }
    }

    func stopDrive() {
        finishDrive()
    }

    /// Hands every fix to `handler` until `endSession()`. Ends a running drive first.
    func beginSession(handler: @escaping @MainActor (CLLocation) -> Void) {
        if mode == .recording { finishDrive() }
        mode = .session
        sessionHandler = handler
        applyLocationMode()
    }

    func endSession() {
        guard mode == .session else { return }
        sessionHandler = nil
        mode = .idle
        applyLocationMode()
    }

    // MARK: Location mode

    /// Full GPS while probing, recording or timing laps; low-power or off when idle.
    private func applyLocationMode() {
        switch mode {
        case .probing, .recording, .session:
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.distanceFilter = kCLDistanceFilterNone
            setUpdating(true)
        case .idle:
            if lowPowerIdle {
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                manager.distanceFilter = 25
                setUpdating(true)
            } else {
                setUpdating(false)
            }
        }
    }

    private func setUpdating(_ on: Bool) {
        guard on != updatingLocation else { return }
        updatingLocation = on
        if on {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    // MARK: Monitoring

    private func applyMonitoring() {
        if autoTrackingEnabled && authorization == .authorizedAlways {
            // Still needed: these relaunch the app after the user force-quits it.
            if CLLocationManager.significantLocationChangeMonitoringAvailable() {
                manager.startMonitoringSignificantLocationChanges()
            }
            manager.startMonitoringVisits()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
        }
        applyLocationMode()
    }

    private func monitorParkingRegion(at coordinate: CLLocationCoordinate2D) {
        guard authorization == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        for region in manager.monitoredRegions where region.identifier == parkingRegionID {
            manager.stopMonitoring(for: region)
        }
        let region = CLCircularRegion(center: coordinate, radius: 100, identifier: parkingRegionID)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    private func startMotionUpdates(force: Bool) {
        guard !motionStarted, CMMotionActivityManager.isActivityAvailable() else { return }
        guard force || CMMotionActivityManager.authorizationStatus() == .authorized else { return }
        motionStarted = true
        motion.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            MainActor.assumeIsolated {
                self?.handleActivity(activity)
            }
        }
    }

    private func handleActivity(_ activity: CMMotionActivity) {
        guard activity.confidence != .low else { return }
        if activity.automotive {
            lastAutomotiveDate = Date()
            startProbingIfAuto(for: 120)
        } else if activity.walking || activity.running {
            lastWalkingDate = Date()
        }
    }

    // MARK: Probing

    private func startProbingIfAuto(for duration: TimeInterval) {
        guard autoTrackingEnabled else { return }
        startProbing(for: duration)
    }

    private func startProbing(for duration: TimeInterval) {
        guard authorization.isAuthorized else { return }
        switch mode {
        case .idle:
            mode = .probing
            fastStreak = 0
            probeStarted = Date()
            probeDeadline = Date().addingTimeInterval(duration)
            applyLocationMode()
        case .probing:
            probeDeadline = max(probeDeadline, Date().addingTimeInterval(duration))
        case .recording, .session:
            break
        }
    }

    private func stopProbing() {
        guard mode == .probing else { return }
        mode = .idle
        lastProbeEnd = Date()
        applyLocationMode()
    }

    // MARK: Location handling

    fileprivate func handle(_ locations: [CLLocation]) {
        for location in locations {
            process(location)
        }
    }

    private func process(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        let previous = lastLocation
        let v = effectiveSpeed(location, previous: previous)
        lastLocation = location
        speed = v

        let stored = SharedStore.lastLocation
        let movedSinceStored = stored.map { Geo.distance($0, location.coordinate) } ?? 0
        if previous == nil || Date().timeIntervalSince(lastSharedSave) > 60 {
            lastSharedSave = Date()
            SharedStore.saveLastLocation(location.coordinate, date: location.timestamp)
            if stored == nil || movedSinceStored > 3000 {
                WidgetCenter.shared.reloadAllTimelines()
            }
        }

        switch mode {
        case .session:
            sessionHandler?(location)
        case .idle:
            remember(location, speed: v)
            let fastEnough = v >= startSpeed && location.horizontalAccuracy <= 100
            let leftParking = SharedStore.parked.map { Geo.distance($0.coordinate, location.coordinate) > 120 } ?? false
            let cooledDown = Date().timeIntervalSince(lastProbeEnd) > 180
            if fastEnough || ((movedSinceStored > 250 || leftParking) && cooledDown) {
                startProbingIfAuto(for: 120)
            }
        case .probing:
            remember(location, speed: v)
            // Start only after three fixes in a row with a measured (Doppler)
            // speed above the threshold and good accuracy. Walking, GPS drift
            // or a single bad fix no longer start a drive.
            if Self.isReliable(location) && location.speed >= startSpeed {
                fastStreak += 1
            } else {
                fastStreak = 0
            }
            if fastStreak >= 3 {
                beginDrive(manual: false)
            }
        case .recording:
            appendDrivePoint(location, speed: v)
        }
    }

    /// Keeps the last 15 minutes of usable fixes so a new drive can start at
    /// the real departure point.
    private func remember(_ location: CLLocation, speed: Double) {
        guard location.horizontalAccuracy <= GPSFilter.maxAccuracy, location.speed >= 0 else { return }
        recentFixes.append(DrivePoint(location: location, speed: speed))
        let cutoff = location.timestamp.timeIntervalSinceReferenceDate - 15 * 60
        recentFixes.removeAll { $0.t < cutoff }
    }

    /// Only the GPS Doppler speed counts. Speeds computed from two positions
    /// jump with every position error (10 m off = 36 km/h) and used to start
    /// drives while standing or walking.
    private func effectiveSpeed(_ location: CLLocation, previous: CLLocation?) -> Double {
        location.speed >= 0 ? location.speed : 0
    }

    private static func isReliable(_ location: CLLocation) -> Bool {
        guard location.speed >= 0,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 20 else { return false }
        return location.speedAccuracy < 0 || location.speedAccuracy <= 1.5
    }

    private func appendDrivePoint(_ location: CLLocation, speed: Double) {
        if speed >= movingSpeed {
            lastMovingDate = Date()
        }
        let fixTime = location.timestamp.timeIntervalSinceReferenceDate
        if speed < 0.6 && location.speed >= 0 {
            // Standing still: the next real acceleration is a launch. A jolt
            // detected before this fix was not one.
            if let pending = pendingLaunch, pending < fixTime - 0.3 { pendingLaunch = nil }
            launchArmed = pendingLaunch == nil
        } else if let pending = pendingLaunch, speed >= 1.5 {
            if fixTime - pending <= 3 { launches.append(pending) }
            pendingLaunch = nil
        }
        guard let cleaned = driveFilter.process(location) else { return }
        var point = DrivePoint(location: location, speed: speed)
        point.lat = cleaned.latitude
        point.lon = cleaned.longitude
        if let relative = relativeAltitude {
            if altitudeAnchor == nil, location.verticalAccuracy > 0, location.verticalAccuracy < 15 {
                altitudeAnchor = location.altitude - relative
            }
            if let anchor = altitudeAnchor { point.alt = anchor + relative }
        }
        if let last = livePoints.last {
            let dt = point.t - last.t
            guard dt >= 0.5 else { return }
            let d = Geo.distance(last.coordinate, point.coordinate)
            if d / dt < 95 { liveDistance += d }
        }
        livePoints.append(point)
        if Self.isReliable(location) {
            liveMaxSpeed = max(liveMaxSpeed, point.speed)
        }
        persistActiveDrive(force: false)
    }

    private func tick() {
        let now = Date()
        switch mode {
        case .probing:
            guard now > probeDeadline else { return }
            let inCar = now.timeIntervalSince(lastAutomotiveDate) < 90
            if inCar && now.timeIntervalSince(probeStarted) < 600 {
                probeDeadline = now.addingTimeInterval(60)
            } else {
                stopProbing()
            }
        case .recording:
            if isManualDrive {
                persistActiveDrive(force: false)
                return
            }
            let still = now.timeIntervalSince(lastMovingDate)
            let walkedAway = lastWalkingDate > lastMovingDate && still > 60
            if still > stopTimeout || walkedAway {
                finishDrive()
            }
        case .idle, .session:
            break
        }
    }

    // MARK: Drive lifecycle

    private func beginDrive(manual: Bool) {
        isManualDrive = manual
        livePoints = manual ? [] : departureFixes()
        recentFixes = []
        driveFilter = GPSFilter()
        fastStreak = 0
        driveStart = livePoints.first?.date ?? Date()
        recomputeLiveStats()
        lastMovingDate = Date()
        driveTemperature = nil
        driveWeatherCode = nil
        launches = []
        launchArmed = false
        mode = .recording
        applyLocationMode()
        startLaunchDetection()
        persistActiveDrive(force: true)
        fetchDriveWeather()
        if !manual {
            backdateToDeparture()
            notifyStarted()
        }
    }

    /// Buffered fixes from the moment the car last stood still.
    private func departureFixes() -> [DrivePoint] {
        guard !recentFixes.isEmpty else { return [] }
        let lastStill = recentFixes.lastIndex { $0.speed < 1.0 } ?? 0
        return Array(recentFixes[lastStill...])
    }

    /// Asks the motion coprocessor when the current car ride began and adds
    /// the parking spot at that moment as the first point.
    private func backdateToDeparture() {
        guard CMMotionActivityManager.isActivityAvailable(), motionAuthorized else {
            prependParkingPoint(at: nil)
            return
        }
        let from = Date().addingTimeInterval(-20 * 60)
        motion.queryActivityStarting(from: from, to: Date(), to: .main) { [weak self] activities, _ in
            var departure: Date?
            for activity in (activities ?? []).reversed() {
                if activity.automotive {
                    departure = activity.startDate
                } else if departure != nil && (activity.walking || activity.running || activity.cycling || activity.stationary) {
                    break
                }
            }
            let result = departure
            MainActor.assumeIsolated {
                self?.prependParkingPoint(at: result)
            }
        }
    }

    private func prependParkingPoint(at departure: Date?) {
        guard mode == .recording, !isManualDrive, let first = livePoints.first else { return }
        guard let parked = SharedStore.parked else { return }
        let distance = Geo.distance(parked.coordinate, first.coordinate)
        guard distance > 15, distance < 2000 else { return }
        // Without motion history assume the car rolled out at ~20 km/h.
        let estimated = first.t - distance / 5.5
        var t = departure?.timeIntervalSinceReferenceDate ?? estimated
        t = max(t, parked.date.timeIntervalSinceReferenceDate + 1)
        guard t < first.t - 1 else { return }
        let start = DrivePoint(t: t, lat: parked.coordinate.latitude, lon: parked.coordinate.longitude,
                               alt: first.alt, speed: 0, course: -1, accuracy: 20)
        livePoints.insert(start, at: 0)
        driveStart = start.date
        liveDistance += distance
        persistActiveDrive(force: true)
    }

    private func recomputeLiveStats() {
        liveDistance = 0
        liveMaxSpeed = 0
        for i in livePoints.indices {
            liveMaxSpeed = max(liveMaxSpeed, livePoints[i].speed)
            if i > 0 {
                liveDistance += Geo.distance(livePoints[i - 1].coordinate, livePoints[i].coordinate)
            }
        }
    }

    private func finishDrive() {
        guard mode == .recording else { return }
        let manual = isManualDrive
        let distance = liveDistance
        let driveLaunches = launches
        var points = livePoints
        if !manual, let lastMoving = points.lastIndex(where: { $0.speed >= movingSpeed }) {
            points = Array(points.prefix(through: min(points.count - 1, lastMoving + 10)))
        }

        mode = .idle
        stopLaunchDetection()
        isManualDrive = false
        livePoints = []
        liveDistance = 0
        liveMaxSpeed = 0
        driveStart = nil
        launches = []
        recentFixes = []
        clearPersistedDrive()
        applyLocationMode()

        guard points.count >= 2, let first = points.first, let last = points.last else { return }
        SharedStore.saveParked(last.coordinate, date: last.date)
        let longEnough = distance >= 300 && last.t - first.t >= 60
        guard longEnough || (manual && points.count >= 5) else { return }

        let drive = Drive(
            startDate: first.date,
            endDate: last.date,
            points: points,
            launches: driveLaunches,
            isManual: manual,
            carID: Persistence.activeCar()?.id
        )
        drive.temperature = driveTemperature
        drive.weatherCode = driveWeatherCode
        Persistence.context.insert(drive)
        Persistence.save()
        lastSavedDriveID = drive.id

        monitorParkingRegion(at: last.coordinate)
        notifySaved(drive)
        WidgetCenter.shared.reloadAllTimelines()
        Task {
            await DriveGeocoder.fill(drive)
        }
    }

    private func fetchDriveWeather() {
        guard let coordinate = lastLocation?.coordinate ?? livePoints.last?.coordinate else { return }
        Task {
            if let weather = try? await WeatherService.fetch(coordinate) {
                self.driveTemperature = weather.temperature
                self.driveWeatherCode = weather.code
            }
        }
    }

    // MARK: Launch detection

    /// 50 Hz accelerometer while recording. When the car stands still and the
    /// acceleration then rises above ~0.06 g for 80 ms, that moment is a launch.
    /// The GPS alone only knows the launch to within one second.
    private func startLaunchDetection() {
        startAltimeter()
        guard motionSensors.isDeviceMotionAvailable, !motionSensors.isDeviceMotionActive else { return }
        motionSensors.deviceMotionUpdateInterval = 1.0 / 50
        let bootOffset = Date().timeIntervalSinceReferenceDate - ProcessInfo.processInfo.systemUptime
        motionSensors.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let a = data.userAcceleration
            let g = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            let time = bootOffset + data.timestamp
            MainActor.assumeIsolated {
                self?.handleAcceleration(g, at: time)
            }
        }
    }

    private func stopLaunchDetection() {
        if motionSensors.isDeviceMotionActive {
            motionSensors.stopDeviceMotionUpdates()
        }
        launchArmed = false
        launchCandidate = nil
        pendingLaunch = nil
        altimeter.stopRelativeAltitudeUpdates()
        relativeAltitude = nil
        altitudeAnchor = nil
    }

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        relativeAltitude = nil
        altitudeAnchor = nil
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let meters = data.relativeAltitude.doubleValue
            MainActor.assumeIsolated {
                self?.relativeAltitude = meters
            }
        }
    }

    private func handleAcceleration(_ g: Double, at time: Double) {
        guard launchArmed else { return }
        if g > 0.06 {
            if launchCandidate == nil {
                launchCandidate = time
                launchSamples = 0
            }
            launchSamples += 1
            if launchSamples >= 4, let candidate = launchCandidate {
                pendingLaunch = candidate
                launchArmed = false
                launchCandidate = nil
            }
        } else {
            launchCandidate = nil
            launchSamples = 0
        }
    }

    // MARK: Notifications

    private func notifyStarted() {
        guard SharedStore.notifyOnStart, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Fahrt erkannt"
        content.body = "Apex zeichnet auf."
        let request = UNNotificationRequest(identifier: "apex.drive.started", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func notifySaved(_ drive: Drive) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["apex.drive.started"])
        let content = UNMutableNotificationContent()
        content.title = "Fahrt gespeichert"
        content.body = "\(Fmt.distance(drive.distance)) · \(Fmt.duration(drive.duration)) · max. \(Fmt.kmh(drive.maxSpeed))"
        let request = UNNotificationRequest(identifier: drive.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: Crash/termination safety

    private var activeDriveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("active-drive.bin")
    }

    private func persistActiveDrive(force: Bool) {
        guard mode == .recording else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastPersist) > 15 else { return }
        lastPersist = now
        try? DrivePoint.encode(livePoints).write(to: activeDriveURL, options: .atomic)
        UserDefaults.standard.set(true, forKey: "activeDriveRunning")
        UserDefaults.standard.set(isManualDrive, forKey: "activeDriveManual")
        UserDefaults.standard.set(launches, forKey: "activeDriveLaunches")
    }

    private func clearPersistedDrive() {
        try? FileManager.default.removeItem(at: activeDriveURL)
        UserDefaults.standard.set(false, forKey: "activeDriveRunning")
        UserDefaults.standard.removeObject(forKey: "activeDriveLaunches")
    }

    private func restoreActiveDrive() {
        guard UserDefaults.standard.bool(forKey: "activeDriveRunning") else { return }
        guard let data = try? Data(contentsOf: activeDriveURL) else {
            clearPersistedDrive()
            return
        }
        let points = DrivePoint.decode(data)
        guard let last = points.last else {
            clearPersistedDrive()
            return
        }
        isManualDrive = UserDefaults.standard.bool(forKey: "activeDriveManual")
        launches = UserDefaults.standard.array(forKey: "activeDriveLaunches") as? [Double] ?? []
        livePoints = points
        driveStart = points.first?.date
        recomputeLiveStats()
        mode = .recording
        if !isManualDrive && Date().timeIntervalSince(last.date) > stopTimeout {
            lastMovingDate = last.date
            finishDrive()
        } else {
            lastMovingDate = Date()
            applyLocationMode()
            startLaunchDetection()
        }
    }

    fileprivate func authorizationChanged(_ status: CLAuthorizationStatus) {
        authorization = status
        if status == .authorizedWhenInUse && wantsAlwaysUpgrade {
            wantsAlwaysUpgrade = false
            manager.requestAlwaysAuthorization()
        }
        applyMonitoring()
        if status.isAuthorized && mode == .idle && UIApplication.shared.applicationState == .active {
            if autoTrackingEnabled {
                startProbing(for: 60)
            } else {
                manager.requestLocation()
            }
        }
    }

    fileprivate func regionExited(_ identifier: String) {
        guard identifier == parkingRegionID else { return }
        startProbingIfAuto(for: 180)
    }

    fileprivate func visitEnded() {
        startProbingIfAuto(for: 180)
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            self.handle(locations)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.authorizationChanged(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is temporary; other errors surface through authorization.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let identifier = region.identifier
        MainActor.assumeIsolated {
            self.regionExited(identifier)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let departed = visit.departureDate != Date.distantFuture
        MainActor.assumeIsolated {
            if departed { self.visitEnded() }
        }
    }
}

extension CLAuthorizationStatus {
    var isAuthorized: Bool {
        self == .authorizedAlways || self == .authorizedWhenInUse
    }

    var label: String {
        switch self {
        case .authorizedAlways: return "Immer"
        case .authorizedWhenInUse: return "Beim Verwenden"
        case .denied: return "Abgelehnt"
        case .restricted: return "Eingeschränkt"
        case .notDetermined: return "Nicht gefragt"
        @unknown default: return "Unbekannt"
        }
    }
}

@MainActor
enum DriveGeocoder {
    static func fill(_ drive: Drive) async {
        let points = drive.points
        guard let first = points.first, let last = points.last else { return }
        let geocoder = CLGeocoder()
        let start = await place(for: first, geocoder: geocoder)
        let end = await place(for: last, geocoder: geocoder)
        drive.startPlace = start
        drive.endPlace = end
        Persistence.save()
    }

    private static func place(for point: DrivePoint, geocoder: CLGeocoder) async -> String? {
        let location = CLLocation(latitude: point.lat, longitude: point.lon)
        guard let placemarks = try? await geocoder.reverseGeocodeLocation(location),
              let placemark = placemarks.first else { return nil }
        return placemark.subLocality ?? placemark.locality ?? placemark.name
    }
}
