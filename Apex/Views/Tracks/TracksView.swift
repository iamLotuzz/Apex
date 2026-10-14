import SwiftUI
import SwiftData
import MapKit

struct TrackLink: Hashable {
    let id: UUID
}

struct SessionLink: Hashable {
    let id: UUID
}

struct TracksView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Track.createdAt, order: .reverse) private var tracks: [Track]
    @Query(sort: \TrackSession.date, order: .reverse) private var sessions: [TrackSession]
    @State private var showEditor = false
    @State private var showRecorder = false
    @State private var pendingDelete: Track?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(tracks) { track in
                    let trackSessions = sessions.filter { $0.trackID == track.id }
                    NavigationLink(value: TrackLink(id: track.id)) {
                        TrackRow(track: track, sessions: trackSessions)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = track
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Strecken")
            .navigationDestination(for: TrackLink.self) { link in
                if let track = tracks.first(where: { $0.id == link.id }) {
                    TrackDetailView(track: track)
                } else {
                    ContentUnavailableView("Strecke gelöscht", systemImage: "trash")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showRecorder = true
                        } label: {
                            Label("Strecke abfahren (Start/Stopp)", systemImage: "record.circle")
                        }
                        Button {
                            showEditor = true
                        } label: {
                            Label("Auf der Karte setzen", systemImage: "map")
                        }
                    } label: {
                        Label("Strecke hinzufügen", systemImage: "plus")
                    }
                }
            }
            .overlay {
                if tracks.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Strecken", systemImage: "flag.checkered")
                    } description: {
                        Text("Fahr die Strecke einmal ab: Start an der Linie, Stopp nach der Runde. Oder setz die Start/Ziel-Linie auf der Karte.")
                    } actions: {
                        Button("Strecke abfahren") { showRecorder = true }
                            .buttonStyle(.glassProminent)
                        Button("Auf der Karte setzen") { showEditor = true }
                            .buttonStyle(.glass)
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                TrackEditorView(track: nil)
            }
            .fullScreenCover(isPresented: $showRecorder) {
                TrackRecorderView { track in
                    path.append(TrackLink(id: track.id))
                }
            }
            .confirmationDialog(
                "Strecke löschen?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Strecke und Sessions löschen", role: .destructive) {
                    if let track = pendingDelete { delete(track) }
                    pendingDelete = nil
                }
            } message: {
                Text("Alle Sessions dieser Strecke werden ebenfalls gelöscht.")
            }
        }
    }

    private func delete(_ track: Track) {
        for session in sessions where session.trackID == track.id {
            context.delete(session)
        }
        MapSnapshotCache.shared.remove(id: track.id)
        context.delete(track)
        try? context.save()
    }
}

private struct TrackRow: View {
    let track: Track
    let sessions: [TrackSession]

    var body: some View {
        HStack(spacing: 14) {
            RouteThumbnail(id: track.id, coordinates: [track.startA.clCoordinate, track.startB.clCoordinate])
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.name)
                    .font(.headline)
                Text(track.kind.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if let best = track.bestLapTime {
                        Label(Fmt.lap(best), systemImage: "trophy.fill")
                            .foregroundStyle(.purple)
                    }
                    Label("\(sessions.count) Sessions", systemImage: "stopwatch")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold))
                .labelStyle(CompactLabelStyle())
            }
        }
        .padding(.vertical, 4)
    }
}
