import Foundation
import CoreMotion

/// Speed, distance and turning between two GPS fixes, for a live display.
///
/// GPS delivers one fix per second, and each one is already a few hundred
/// milliseconds old on arrival. Phones without dual-frequency GPS (like the
/// iPhone 13 Pro) are also a few metres less precise in cities. In between
/// fixes this integrates the phone's motion sensors (50 Hz), so speed,
/// position and heading change continuously:
///
/// - Accelerometer along the direction of travel: braking and accelerating
///   show up immediately. The travel direction in the phone's frame is
///   learned by correlating the horizontal acceleration with the change of
///   the GPS Doppler speed; lateral forces in corners do not correlate and
///   average out. Moving the phone (new gravity direction) starts over.
/// - Gyroscope around the vertical axis: the car turns with the road at
///   once instead of on the next fix. Mount independent, because the
///   rotation is projected onto gravity.
/// - Every fix pulls the integrated speed back to the Doppler speed and
///   estimates the sensor bias, so the integration never drifts.
/// - Without GPS (tunnel, garage) it keeps going for up to 90 s: with the
///   sensors when the direction is known, otherwise at the last speed.
///
/// Performance: the integration runs once per sensor sample (50 Hz) and is
/// kept as a running state. A screen frame (up to 120 Hz) only extrapolates
/// from that state, so its cost does not grow with the time since the fix.
@MainActor
final class LiveMotion {
    /// Longest extrapolation without a fix (tunnels).
    static let maxCoast: TimeInterval = 90

    private let motion = CMMotionManager()

    private struct Sample {
        var t: TimeInterval
        /// Longitudinal acceleration in m/s², nil while the direction is unknown.
        var a: Double?
        /// Heading change rate in degrees per second (clockwise positive).
        var yaw: Double
    }

    /// Integrated motion since the last fix, in the frame of the course at
    /// the fix: `forward` along it, `right` to its right, `turned` degrees.
    private struct Integration {
        var t: TimeInterval
        var v: Double
        var distance = 0.0
        var forward = 0.0
        var right = 0.0
        var turned = 0.0
        var yaw = 0.0
        /// Speed gained from a standstill, as felt by the accelerometer.
        var startOff = 0.0
    }

    /// Only the last few seconds, to re-integrate when a (late) fix arrives.
    private var recent: [Sample] = []
    private var state: Integration?

    // Fix anchor
    private var anchorTime: TimeInterval?
    private var anchorSpeed = 0.0
    private var lastGPSSpeed: Double?
    private var lastGPSTime: TimeInterval = 0
    private var slope = 0.0
    private var standing = true

    // Direction learning (phone frame)
    private var gravityRef: Vec3?
    private var direction = Vec3.zero
    private var weight = 0.0
    private var intervalSum = Vec3.zero
    private var intervalCount = 0
    private var bias = 0.0

    func start() {
        reset()
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        let bootOffset = Date().timeIntervalSinceReferenceDate - ProcessInfo.processInfo.systemUptime
        // Delivered on the main queue directly: no task per sample.
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let g = Vec3(x: data.gravity.x, y: data.gravity.y, z: data.gravity.z)
            let u = Vec3(x: data.userAcceleration.x, y: data.userAcceleration.y, z: data.userAcceleration.z)
            let r = Vec3(x: data.rotationRate.x, y: data.rotationRate.y, z: data.rotationRate.z)
            let time = bootOffset + data.timestamp
            MainActor.assumeIsolated {
                self?.sample(gravity: g, user: u, rotation: r, time: time)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        reset()
    }

    private func reset() {
        recent = []
        state = nil
        anchorTime = nil
        anchorSpeed = 0
        lastGPSSpeed = nil
        slope = 0
        standing = true
        gravityRef = nil
        direction = .zero
        weight = 0
        intervalSum = .zero
        intervalCount = 0
        bias = 0
    }

    /// Whether the travel direction in the phone is known well enough.
    private var directionKnown: Bool {
        weight > 4 && direction.length / weight > 0.55
    }

    private func sample(gravity: Vec3, user: Vec3, rotation: Vec3, time: TimeInterval) {
        let gLength = gravity.length
        guard gLength > 0.5 else { return }
        let down = gravity * (1 / gLength)
        if let ref = gravityRef, ref.dot(down) < cos(15 * Double.pi / 180) {
            // The phone was moved: the learned direction no longer applies.
            direction = .zero
            weight = 0
            bias = 0
            gravityRef = down
        } else if gravityRef == nil {
            gravityRef = down
        }
        // Horizontal part of the acceleration, in m/s².
        let horizontal = (user - down * user.dot(down)) * 9.81
        intervalSum = intervalSum + horizontal
        intervalCount += 1

        // Rotation around the vertical axis. A left turn (counter-clockwise
        // seen from above) lowers the compass heading.
        var yaw = rotation.dot(down) * 180 / .pi
        if abs(yaw) < 0.4 { yaw = 0 }
        yaw = min(90, max(-90, yaw))

        var a: Double?
        if directionKnown {
            let unit = direction * (1 / direction.length)
            a = min(12, max(-12, horizontal.dot(unit) - bias))
        }
        let sample = Sample(t: time, a: a, yaw: yaw)
        recent.append(sample)
        if recent.count > 200 { recent.removeFirst(recent.count - 200) }
        integrate(sample)
    }

    /// Speed the model expects at `time` (since the anchor) without sensor
    /// acceleration: the trend of the last fixes for 2 s, then constant.
    private func trendSpeed(at time: TimeInterval) -> Double {
        guard let start = anchorTime, !standing else { return 0 }
        return max(0, anchorSpeed + slope * min(max(0, time - start), 2.0))
    }

    private func integrate(_ s: Sample) {
        guard var st = state, let start = anchorTime, s.t > st.t, s.t <= start + Self.maxCoast else { return }
        let dt = s.t - st.t
        if standing {
            st.startOff = max(0, st.startOff + (s.a ?? 0) * dt)
            st.t = s.t
            state = st
            return
        }
        let next = s.a.map { max(0, st.v + $0 * dt) } ?? trendSpeed(at: s.t)
        let step = (st.v + next) * 0.5 * dt
        // Midpoint heading for this step.
        let midTurn = st.turned + s.yaw * dt * 0.5
        let radians = midTurn * .pi / 180
        st.distance += step
        st.forward += step * cos(radians)
        st.right += step * sin(radians)
        st.turned += s.yaw * dt
        st.yaw = s.yaw
        st.v = next
        st.t = s.t
        state = st
    }

    /// Feeds a GPS fix. `speed` is the Doppler speed in m/s.
    func fix(time: Date, speed: Double, speedAccuracy: Double) {
        let t = time.timeIntervalSinceReferenceDate
        let gps = max(0, speed)
        let accuracy = speedAccuracy >= 0 ? speedAccuracy : 1

        // Learn the travel direction from the GPS acceleration.
        if let previous = lastGPSSpeed {
            let dt = t - lastGPSTime
            if dt > 0.3 && dt < 2.5 && intervalCount > 5 && accuracy < 1.5 && gps > 1.5 {
                let gpsAccel = (gps - previous) / dt
                let mean = intervalSum * (1 / Double(intervalCount))
                if abs(gpsAccel) > 0.25 {
                    direction = direction * 0.97 + mean * gpsAccel
                    weight = weight * 0.97 + mean.length * abs(gpsAccel)
                }
                slope = slope * 0.4 + min(8, max(-10, gpsAccel)) * 0.6
            } else if dt > 0 && dt < 2.5 {
                slope = slope * 0.4 + min(8, max(-10, (gps - previous) / max(dt, 0.3))) * 0.6
            }
        }
        intervalSum = .zero
        intervalCount = 0

        // Fuse: modelled speed at the fix time vs. Doppler speed.
        if let previousTime = anchorTime, t - previousTime < 5, t > previousTime {
            let predicted = speedAt(t)
            let error = gps - predicted
            let gain = accuracy < 0.6 ? 0.75 : 0.55
            anchorSpeed = max(0, predicted + error * gain)
            if directionKnown {
                let dt = max(0.3, t - previousTime)
                bias -= min(0.3, max(-0.3, error / dt * 0.15))
            }
        } else {
            anchorSpeed = gps
        }
        standing = gps < 0.6
        if standing { anchorSpeed = gps; slope = 0 }
        anchorTime = t
        lastGPSSpeed = gps
        lastGPSTime = t

        // Fixes arrive late: integrate the samples measured since then.
        state = Integration(t: t, v: standing ? 0 : anchorSpeed)
        for s in recent where s.t > t { integrate(s) }
    }

    /// Modelled speed at `t` from the running integration.
    private func speedAt(_ t: TimeInterval) -> Double {
        guard let st = state else { return anchorSpeed }
        if standing {
            // Starting off is shown as soon as the sensor feels it.
            return directionKnown && st.startOff > 0.8 ? st.startOff : 0
        }
        if !directionKnown { return trendSpeed(at: t) }
        return st.v
    }

    /// Live speed in m/s.
    func speed(at date: Date) -> Double {
        guard let start = anchorTime else { return 0 }
        let t = min(date.timeIntervalSinceReferenceDate, start + Self.maxCoast)
        return speedAt(t)
    }

    /// Metres driven since the last fix's measurement time.
    func distanceSinceFix(at date: Date, coast: Bool) -> Double {
        extrapolated(at: date, coast: coast)?.distance ?? 0
    }

    /// Offset in metres (east, north) and the turned course since the fix,
    /// starting from `course`, following the gyroscope.
    func track(from course: Double, at date: Date, coast: Bool) -> (east: Double, north: Double, course: Double) {
        guard let e = extrapolated(at: date, coast: coast) else { return (0, 0, course) }
        let c = course * .pi / 180
        // Rotate (forward, right) from the course frame into east/north.
        let east = e.forward * sin(c) + e.right * cos(c)
        let north = e.forward * cos(c) - e.right * sin(c)
        return (east, north, course + e.turned)
    }

    /// The running state carried forward from its last sample to `date`.
    private func extrapolated(at date: Date, coast: Bool) -> Integration? {
        guard var st = state, let start = anchorTime else { return nil }
        let end = min(date.timeIntervalSinceReferenceDate, start + (coast ? Self.maxCoast : 2.0))
        if standing { return st }
        if end > st.t {
            let dt = end - st.t
            let v = directionKnown ? st.v : trendSpeed(at: end)
            let step = (st.v + v) * 0.5 * dt
            let radians = (st.turned + st.yaw * dt * 0.5) * .pi / 180
            st.distance += step
            st.forward += step * cos(radians)
            st.right += step * sin(radians)
            st.turned += st.yaw * dt
            st.v = v
            st.t = end
        }
        return st
    }
}

struct Vec3 {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Vec3(x: 0, y: 0, z: 0)

    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func * (a: Vec3, s: Double) -> Vec3 { Vec3(x: a.x * s, y: a.y * s, z: a.z * s) }

    func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    var length: Double { dot(self).squareRoot() }
}
