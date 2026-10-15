import SwiftUI
import CoreLocation
import UIKit

/// Full-screen landscape lap timer: huge delta, speed and lap times.
struct LiveSessionView: View {
    let trackModel: Track
    var onFinish: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var timer: LapTimer
    @State private var showEndDialog = false
    @State private var flashColor: Color?
    @State private var banner: Lap?
    @State private var bannerDelta: Double?
    @State private var finished = false
    private let carImage: UIImage

    init(track: Track, reference: LapReference, storedReference: Lap? = nil, onFinish: @escaping (UUID?) -> Void) {
        self.trackModel = track
        self.onFinish = onFinish
        _timer = State(initialValue: LapTimer(track: track.snapshot, reference: reference, storedReference: storedReference))
        self.carImage = Persistence.activeCar()?.frontImage ?? DefaultPixelCar.frontImage
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    HStack(spacing: 0) {
                        deltaPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Rectangle()
                            .fill(.white.opacity(0.12))
                            .frame(width: 1)
                            .padding(.vertical, 24)
                        speedPanel
                            .frame(width: geo.size.width * 0.34)
                            .frame(maxHeight: .infinity)
                    }
                    deltaBar
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                    bottomBar
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if let banner {
                    lapBanner(banner)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }

                if let flashColor {
                    flashColor
                        .opacity(0.35)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: start)
        .onDisappear(perform: cleanUp)
        .onChange(of: timer.eventCount) { _, _ in
            handleEvent()
        }
        .confirmationDialog("Session beenden?", isPresented: $showEndDialog, titleVisibility: .visible) {
            Button("Beenden & speichern") { finish(save: true) }
            Button("Verwerfen", role: .destructive) { finish(save: false) }
            Button("Weiterfahren", role: .cancel) {}
        } message: {
            Text(timer.laps.isEmpty ? "Noch keine Runde gezeitet." : "\(timer.laps.count) Runden gezeitet.")
        }
    }

    // MARK: Panels

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                showEndDialog = true
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: .circle)

            PixelImage(image: carImage)
                .frame(width: 40, height: 24)
            Text(trackModel.name)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 8)

            lapIndicator

            Spacer(minLength: 8)

            gpsIndicator
        }
    }

    /// "RUNDE 3" in large type; the capsule fills up as the lap progresses
    /// (measured along the reference lap).
    private var lapIndicator: some View {
        let progress = timer.lapProgress ?? 0
        return HStack(alignment: .center, spacing: 8) {
            if timer.phase == .running {
                Text("Runde")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                Text("\(timer.currentLapNumber)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(timer.currentLapNumber)))
                if timer.lapProgress != nil {
                    Text("\(Int((progress * 100).rounded())) %")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                }
            } else {
                Text(timer.laps.isEmpty ? "Bereit" : "Im Ziel")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.orange.opacity(0.35), Color.orange.opacity(0.75)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: progress > 0 ? max(36, geo.size.width * progress) : 0)
                }
            }
        }
        .clipShape(.capsule)
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1))
        .animation(.linear(duration: 0.9), value: progress)
        .accessibilityElement(children: .combine)
    }

    private var gpsIndicator: some View {
        let accuracy = timer.accuracy
        let color: Color = accuracy < 0 ? .gray : (accuracy <= 8 ? .green : (accuracy <= 20 ? .yellow : .red))
        return HStack(spacing: 6) {
            Image(systemName: "location.fill")
            Text(accuracy < 0 ? "GPS" : "±\(Int(accuracy)) m")
                .monospacedDigit()
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private var deltaText: String {
        guard timer.phase == .running else { return "––" }
        guard let delta = timer.delta else { return "––" }
        return Fmt.delta(delta)
    }

    private var deltaColor: Color {
        guard let delta = timer.delta, timer.phase == .running else { return .white }
        if abs(delta) < 0.05 { return .white }
        return delta < 0 ? Color(red: 0.2, green: 0.95, blue: 0.45) : Color(red: 1.0, green: 0.27, blue: 0.27)
    }

    private var deltaPanel: some View {
        VStack(spacing: 6) {
            if timer.phase == .waitingForStart && timer.laps.isEmpty {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 54))
                Text("Fahr über die Start/Ziel-Linie")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Die Zeitmessung startet automatisch.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text(deltaText)
                    .font(.system(size: 130, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(deltaColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .contentTransition(.numericText(value: timer.delta ?? 0))
                    .animation(.snappy(duration: 0.25), value: timer.delta)
                Text(deltaCaption)
                    .font(.caption.weight(.heavy))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 8)
    }

    private var deltaCaption: String {
        if timer.phase == .waitingForStart { return "WARTE AUF STARTLINIE" }
        if timer.referenceLap == nil { return "ERSTE RUNDE – REFERENZ WIRD AUFGEZEICHNET" }
        if timer.referenceIsStored { return "Δ ZUR BESTZEIT AUS FRÜHEREN SESSIONS" }
        return timer.reference == .previous ? "Δ ZUR VORHERIGEN RUNDE" : "Δ ZUR BESTEN RUNDE"
    }

    private var speedPanel: some View {
        VStack(spacing: 0) {
            Text("\(Int((timer.speed * 3.6).rounded()))")
                .font(.system(size: 110, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .contentTransition(.numericText(value: timer.speed))
                .animation(.snappy(duration: 0.25), value: timer.speed)
            Text("KM/H")
                .font(.headline.weight(.heavy))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var deltaBar: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let value = max(-2, min(2, timer.delta ?? 0))
            let width = abs(value) / 2 * half
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.1))
                Rectangle()
                    .fill(value < 0 ? Color.green : Color.red)
                    .frame(width: width)
                    .offset(x: value < 0 ? half - width : half)
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .offset(x: half - 1)
            }
            .clipShape(.capsule)
            .animation(.snappy(duration: 0.3), value: value)
        }
        .frame(height: 10)
    }

    private var bottomBar: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: timer.phase != .running)) { _ in
            HStack(spacing: 10) {
                timeBlock("AKTUELL", timer.phase == .running ? Fmt.lap(timer.currentLapTime, digits: 1) : "–", highlight: true)
                timeBlock("LETZTE", timer.lastLap.map { Fmt.lap($0.duration) } ?? "–")
                timeBlock("BESTE", timer.bestLap.map { Fmt.lap($0.duration) } ?? "–", color: .purple)
                timeBlock("PROGNOSE", timer.predictedLapTime.map { Fmt.lap($0, digits: 1) } ?? "–")
            }
        }
    }

    private func timeBlock(_ title: String, _ value: String, highlight: Bool = false, color: Color = .white) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.heavy))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: highlight ? 30 : 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func lapBanner(_ lap: Lap) -> some View {
        VStack(spacing: 6) {
            Text("RUNDE \(lap.number)")
                .font(.headline.weight(.heavy))
                .tracking(2)
            Text(Fmt.lap(lap.duration))
                .font(.system(size: 72, weight: .heavy, design: .rounded))
                .monospacedDigit()
            if let bannerDelta {
                Text(Fmt.delta(bannerDelta, digits: 3))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(bannerDelta < 0 ? Color.green : Color.red)
            }
            if timer.bestLap?.number == lap.number {
                Label("Neue Bestzeit", systemImage: "trophy.fill")
                    .font(.headline)
                    .foregroundStyle(.purple)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
        .glassEffect(.regular.tint(Color.black.opacity(0.4)), in: .rect(cornerRadius: 32))
    }

    // MARK: Flow

    private func start() {
        OrientationController.lock(.landscape)
        UIApplication.shared.isIdleTimerDisabled = true
        let timer = self.timer
        LocationService.shared.beginSession { location in
            timer.process(location)
        }
    }

    private func handleEvent() {
        guard let event = timer.lastEvent else { return }
        switch event {
        case .started:
            flashColor = Color.green
        case .lapCompleted(_, let isBest):
            flashColor = isBest ? Color.purple : Color.white
            if let lap = timer.lastLap {
                let others = timer.laps.dropLast()
                let compare = timer.reference == .previous ? others.last?.duration : others.map(\.duration).min()
                bannerDelta = compare.map { lap.duration - $0 }
                withAnimation(.spring(duration: 0.35)) { banner = lap }
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    if banner?.number == lap.number {
                        withAnimation(.easeOut(duration: 0.3)) { banner = nil }
                    }
                }
            }
        case .finished:
            flashColor = Color.white
        }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.easeOut(duration: 0.9)) { flashColor = nil }
        }
    }

    private func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        LocationService.shared.endSession()
        let saved = save ? SessionStore.save(timer: timer, track: trackModel) : nil
        cleanUp()
        dismiss()
        onFinish(saved?.id)
    }

    private func cleanUp() {
        if LocationService.shared.mode == .session {
            LocationService.shared.endSession()
        }
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationController.lock(.portrait)
    }
}
