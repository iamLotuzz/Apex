import SwiftUI
import SwiftData

struct DrivesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Drive.startDate, order: .reverse) private var drives: [Drive]
    @Query(sort: \Car.createdAt) private var cars: [Car]

    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var showLiveDrive = false
    @State private var showSettings = false
    @State private var pendingDelete: [Drive] = []
    @State private var filter: DriveFilter = .all

    private var location: LocationService { .shared }

    enum DriveFilter: String, CaseIterable, Identifiable {
        case all, favorites, manual
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Alle Fahrten"
            case .favorites: return "Favoriten"
            case .manual: return "Manuell gestartet"
            }
        }
    }

    private var filtered: [Drive] {
        switch filter {
        case .all: return drives
        case .favorites: return drives.filter(\.isFavorite)
        case .manual: return drives.filter(\.isManual)
        }
    }

    struct MonthSection: Identifiable {
        let month: Date
        let drives: [Drive]
        var id: Date { month }
        var title: String { month.formatted(.dateTime.month(.wide).year()) }
    }

    private var sections: [MonthSection] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { drive in
            calendar.dateInterval(of: .month, for: drive.startDate)?.start ?? drive.startDate
        }
        return groups.keys.sorted(by: >).map { month in
            MonthSection(month: month, drives: groups[month] ?? [])
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if location.isRecording {
                    Section {
                        LiveDriveBanner { showLiveDrive = true }
                    }
                }

                if !drives.isEmpty {
                    Section {
                        WeekSummary(drives: drives)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.drives) { drive in
                            NavigationLink(value: DriveLink(id: drive.id)) {
                                DriveRow(drive: drive, car: cars.count > 1 ? cars.first(where: { $0.id == drive.carID }) : nil)
                            }
                            .tag(drive.id)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete([drive])
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    drive.isFavorite.toggle()
                                } label: {
                                    Label("Favorit", systemImage: drive.isFavorite ? "star.slash" : "star")
                                }
                                .tint(.yellow)
                            }
                            .contextMenu {
                                Button {
                                    drive.isFavorite.toggle()
                                } label: {
                                    Label(drive.isFavorite ? "Kein Favorit" : "Favorit", systemImage: "star")
                                }
                                Button(role: .destructive) {
                                    pendingDelete = [drive]
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .navigationTitle("Fahrten")
            .navigationDestination(for: DriveLink.self) { link in
                if let drive = drives.first(where: { $0.id == link.id }) {
                    DriveDetailView(drive: drive)
                } else {
                    ContentUnavailableView("Fahrt gelöscht", systemImage: "trash")
                }
            }
            .overlay {
                if drives.isEmpty && !location.isRecording {
                    ContentUnavailableView {
                        Label("Noch keine Fahrten", systemImage: "road.lanes")
                    } description: {
                        Text("Fahr los – ab \(Int(SharedStore.startSpeedKmh)) km/h zeichnet Apex automatisch auf. Oder starte eine Fahrt manuell.")
                    } actions: {
                        Button("Fahrt jetzt starten") {
                            location.startManualDrive()
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .toolbar { toolbar }
            .sheet(isPresented: $showLiveDrive) {
                LiveDriveView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .confirmationDialog(
                pendingDelete.count == 1 ? "Fahrt löschen?" : "\(pendingDelete.count) Fahrten löschen?",
                isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                titleVisibility: .visible
            ) {
                Button("Löschen", role: .destructive) {
                    delete(pendingDelete)
                    pendingDelete = []
                }
            } message: {
                Text("Das kann nicht rückgängig gemacht werden.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if editMode.isEditing {
                Button(role: .destructive) {
                    pendingDelete = drives.filter { selection.contains($0.id) }
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            } else {
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(DriveFilter.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    }
                } label: {
                    Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        ToolbarItem(placement: .principal) {
            if location.isRecording {
                Button {
                    showLiveDrive = true
                } label: {
                    LivePill()
                }
                .buttonStyle(.plain)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !drives.isEmpty {
                Button(editMode.isEditing ? "Fertig" : "Auswählen") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                        if !editMode.isEditing { selection.removeAll() }
                    }
                }
            }
            Menu {
                if location.isRecording {
                    Button {
                        location.stopDrive()
                    } label: {
                        Label("Fahrt beenden", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        location.startManualDrive()
                        showLiveDrive = true
                    } label: {
                        Label("Fahrt manuell starten", systemImage: "play.fill")
                    }
                }
                Button {
                    showSettings = true
                } label: {
                    Label("Einstellungen", systemImage: "gearshape")
                }
            } label: {
                Label("Mehr", systemImage: "ellipsis")
            }
        }
    }

    private func delete(_ items: [Drive]) {
        for drive in items {
            MapSnapshotCache.shared.remove(id: drive.id)
            selection.remove(drive.id)
            context.delete(drive)
        }
        try? context.save()
    }
}

private struct WeekSummary: View {
    let drives: [Drive]

    private var weekDrives: [Drive] {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return drives.filter { $0.startDate >= start }
    }

    var body: some View {
        let week = weekDrives
        let distance = week.reduce(0.0) { $0 + $1.distance }
        let time = week.reduce(0.0) { $0 + $1.duration }
        let top = week.map(\.maxSpeed).max() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            Text("Diese Woche")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                MiniStat(value: Fmt.km(distance), caption: "km")
                MiniStat(value: "\(week.count)", caption: week.count == 1 ? "Fahrt" : "Fahrten")
                MiniStat(value: Fmt.duration(time), caption: "Fahrzeit")
                MiniStat(value: Fmt.kmhValue(top), caption: "max. km/h")
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.vertical, 4)
    }
}

/// Value pushed when a drive row is tapped. A dedicated type keeps
/// navigation separate from the list's edit selection (also UUIDs).
struct DriveLink: Hashable {
    let id: UUID
}

/// Red capsule with the elapsed time, like the call indicator in iOS.
struct LivePill: View {
    var showsDuration = true
    private var location: LocationService { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Label {
                if showsDuration {
                    Text(Fmt.clock(location.liveDuration))
                        .monospacedDigit()
                } else {
                    Text("Live")
                }
            } icon: {
                Image(systemName: "car.fill")
                    .symbolEffect(.pulse)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.red, in: .capsule)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fahrt läuft")
    }
}

/// The running drive as a regular list row: app-style icon, title,
/// distance and time, and the current speed on the trailing side.
struct LiveDriveBanner: View {
    var onOpen: () -> Void
    private var location: LocationService { .shared }

    var body: some View {
        Button(action: onOpen) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 14) {
                    Image(systemName: "car.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.red.gradient, in: .rect(cornerRadius: 11))
                        .symbolEffect(.pulse)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.isManualDrive ? "Fahrt läuft (manuell)" : "Fahrt läuft")
                            .font(.headline)
                        Text("\(Fmt.distance(location.liveDistance)) · \(Fmt.clock(location.liveDuration))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Fmt.kmhValue(location.speed))
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("km/h")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
    }
}
