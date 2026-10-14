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
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
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
                            NavigationLink(value: drive.id) {
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
            .navigationDestination(for: UUID.self) { id in
                if let drive = drives.first(where: { $0.id == id }) {
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

/// Red "LIVE · 0:18:32" capsule shown while a drive records.
struct LivePill: View {
    var showsDuration = true
    private var location: LocationService { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text("LIVE")
                    .font(.caption.weight(.heavy))
                    .tracking(1.2)
                if showsDuration {
                    Text(Fmt.clock(location.liveDuration))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .glassEffect(.regular.tint(Color.red.opacity(0.22)), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fahrt läuft")
    }
}

/// The running drive at the top of the list: status line, big speed,
/// distance and duration.
struct LiveDriveBanner: View {
    var onOpen: () -> Void
    private var location: LocationService { .shared }

    var body: some View {
        Button(action: onOpen) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse)
                        Text(location.isManualDrive ? "FAHRT LÄUFT · MANUELL" : "FAHRT LÄUFT")
                            .font(.caption.weight(.heavy))
                            .tracking(1.4)
                            .foregroundStyle(.red)
                        Spacer()
                        if let start = location.driveStart {
                            Text("seit \(Fmt.time(start))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(alignment: .lastTextBaseline) {
                        HStack(alignment: .lastTextBaseline, spacing: 4) {
                            Text(Fmt.kmhValue(location.speed))
                                .font(.system(size: 46, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("km/h")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.distance(location.liveDistance))
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .monospacedDigit()
                            Text(Fmt.clock(location.liveDuration))
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.red.opacity(0.10)).interactive(), in: .rect(cornerRadius: 26))
        .padding(.vertical, 4)
    }
}