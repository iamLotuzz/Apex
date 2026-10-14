import SwiftUI
import CoreLocation
import UserNotifications

struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var step = 0
    private var location: LocationService { .shared }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    PixelImage(image: DefaultPixelCar.image)
                        .frame(width: 180)
                        .padding(.top, 48)

                    if step == 0 {
                        welcome
                    } else {
                        permissions
                    }
                }
                .padding(.horizontal, 28)
            }

            VStack(spacing: 12) {
                if step == 0 {
                    Button {
                        withAnimation(.smooth) { step = 1 }
                    } label: {
                        Text("Weiter")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button {
                        onFinish()
                    } label: {
                        Text("Los geht's")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Willkommen bei Apex")
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            FeatureRow(symbol: "road.lanes", color: .orange, title: "Fahrten automatisch", text: "Ab 10 km/h startet die Aufzeichnung von selbst – mit Karte, Tempo und vielen Statistiken.")
            FeatureRow(symbol: "flag.checkered", color: .red, title: "Rundenzeiten", text: "Lege Rennstrecken an und sieh live das Delta zur letzten Runde im Querformat.")
            FeatureRow(symbol: "car.side.fill", color: .blue, title: "Deine Garage", text: "Dein Auto als Pixel-Art, Fahrzeugdaten und Gesamtstatistik.")
            FeatureRow(symbol: "fuelpump.fill", color: .green, title: "Wetter & Sprit", text: "Fahrbedingungen in deiner Nähe und die günstigsten Tankstellen – auch auf dem Sperrbildschirm.")
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Berechtigungen")
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Für den Auto-Start braucht Apex den Standort auf „Immer“. Die Daten bleiben auf deinem iPhone.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            PermissionRow(
                symbol: "location.fill",
                title: "Standort",
                status: location.authorization.label,
                done: location.authorization == .authorizedAlways
            ) {
                location.requestPermission()
            }

            PermissionRow(
                symbol: "figure.walk.motion",
                title: "Bewegung & Fitness",
                status: location.motionAuthorized ? "Erlaubt" : "Optional",
                done: location.motionAuthorized
            ) {
                location.requestMotionPermission()
            }

            NotificationPermissionRow()

            Text("Tipp: Wenn iOS nur „Beim Verwenden“ anbietet, tippe später in den Einstellungen auf Standort → Immer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let status: String
    let done: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(done ? Color.green : Color.orange, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                Button("Erlauben", action: action)
                    .buttonStyle(.glass)
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
    }
}

private struct NotificationPermissionRow: View {
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        PermissionRow(
            symbol: "bell.badge.fill",
            title: "Mitteilungen",
            status: status == .authorized ? "Erlaubt" : "Für „Fahrt gespeichert“",
            done: status == .authorized
        ) {
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await refresh()
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
    }
}
