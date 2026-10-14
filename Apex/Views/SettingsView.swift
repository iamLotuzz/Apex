import SwiftUI
import SwiftData
import CoreLocation
import WidgetKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SharedStore.Key.autoTracking, store: SharedStore.defaults) private var autoTracking = true
    @AppStorage(SharedStore.Key.instantStart, store: SharedStore.defaults) private var instantStart = true
    @AppStorage(SharedStore.Key.notifyOnStart, store: SharedStore.defaults) private var notifyOnStart = true
    @AppStorage(SharedStore.Key.startSpeedKmh, store: SharedStore.defaults) private var startSpeed = 10.0
    @AppStorage(SharedStore.Key.stopMinutes, store: SharedStore.defaults) private var stopMinutes = 4.0
    @AppStorage(SharedStore.Key.apiKey, store: SharedStore.defaults) private var apiKey = ""
    @AppStorage(SharedStore.Key.fuelRadiusKm, store: SharedStore.defaults) private var radius = 5.0
    @AppStorage(SharedStore.Key.lapReference, store: SharedStore.defaults) private var lapReference = LapReference.previous.rawValue

    @State private var confirmDeleteAll = false
    @State private var demoMessage: String?

    private var location: LocationService { .shared }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Fahrten automatisch erkennen", isOn: $autoTracking)
                    Toggle(isOn: $instantStart) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sofort-Start")
                            Text("Erkennt die Abfahrt in Sekunden, braucht etwas mehr Akku")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!autoTracking)
                    Toggle("Mitteilung bei Fahrtbeginn", isOn: $notifyOnStart)
                        .disabled(!autoTracking)
                    Stepper(value: $startSpeed, in: 5...40, step: 1) {
                        LabeledContent("Start ab", value: "\(Int(startSpeed)) km/h")
                    }
                    Picker("Ende nach Stillstand", selection: $stopMinutes) {
                        ForEach([2.0, 3.0, 4.0, 5.0, 8.0, 10.0], id: \.self) { minutes in
                            Text("\(Int(minutes)) min").tag(minutes)
                        }
                    }
                    LabeledContent("Standortzugriff", value: location.authorization.label)
                    if location.authorization != .authorizedAlways {
                        Button("Standort auf „Immer“ stellen") {
                            location.requestPermission()
                        }
                    }
                    LabeledContent("Status", value: statusText)
                } header: {
                    Text("Automatische Fahrten")
                } footer: {
                    Text("Ab der Startgeschwindigkeit läuft die Aufzeichnung. Die Fahrt beginnt trotzdem am Parkplatz: Apex rechnet sie auf den Moment zurück, in dem das Auto losgefahren ist. Ohne Sofort-Start weckt iOS die App erst nach einigen hundert Metern.")
                }

                Section {
                    TextField("Tankerkönig API-Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Link(destination: FuelAPI.signupURL) {
                        Label("Kostenlosen API-Key holen", systemImage: "key.fill")
                    }
                    Stepper(value: $radius, in: 1...25, step: 1) {
                        LabeledContent("Suchradius", value: "\(Int(radius)) km")
                    }
                    LabeledContent("Kraftstoff", value: SharedStore.fuelType.title)
                    if !SharedStore.isGroupAvailable {
                        Label("App Group nicht verfügbar: Das Widget sieht keine Daten. Installiere die App über AltStore neu.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Tankstellen & Widget")
                } footer: {
                    Text("Ohne eigenen Key zeigt Apex Demo-Preise. Den Kraftstoff stellst du beim Auto in der Garage ein.")
                }

                Section("Rundenzeiten") {
                    Picker("Delta-Referenz", selection: $lapReference) {
                        ForEach(LapReference.allCases) { ref in
                            Text(ref.title).tag(ref.rawValue)
                        }
                    }
                }

                Section {
                    Button("Demo-Daten erzeugen") {
                        let center = location.lastLocation?.coordinate
                            ?? SharedStore.lastLocation
                            ?? CLLocationCoordinate2D(latitude: 50.3356, longitude: 6.9475)
                        DemoData.generate(around: center)
                        demoMessage = "6 Demo-Fahrten, ein zweites Auto und eine Demo-Strecke angelegt."
                    }
                    if let demoMessage {
                        Text(demoMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Alle Fahrten löschen", role: .destructive) {
                        confirmDeleteAll = true
                    }
                } header: {
                    Text("Daten")
                } footer: {
                    Text("Alle Daten bleiben auf diesem iPhone.")
                }

                Section("Info") {
                    LabeledContent("Version", value: version)
                    Text("Wetter: Open-Meteo.com (CC BY 4.0) · Tankpreise: Tankerkönig / MTS-K (CC BY 4.0) · Karten: Apple Maps")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onChange(of: autoTracking) { _, _ in location.settingsChanged() }
            .onChange(of: instantStart) { _, _ in location.settingsChanged() }
            .onChange(of: apiKey) { _, _ in WidgetCenter.shared.reloadAllTimelines() }
            .onChange(of: radius) { _, _ in WidgetCenter.shared.reloadAllTimelines() }
            .confirmationDialog("Alle Fahrten löschen?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Alle löschen", role: .destructive) {
                    Persistence.deleteAllDrives()
                }
            } message: {
                Text("Strecken und Sessions bleiben erhalten.")
            }
        }
    }

    private var statusText: String {
        switch location.mode {
        case .idle: return autoTracking ? "Wartet auf Fahrt" : "Aus"
        case .probing: return "Prüft Geschwindigkeit …"
        case .recording: return "Zeichnet auf"
        case .session: return "Track-Session"
        }
    }
}
