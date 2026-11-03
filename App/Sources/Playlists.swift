import SwiftUI

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var tracks: [Track]
}

/// Your playlists, stored on the phone only.
@MainActor
final class Playlists: ObservableObject {
    static let shared = Playlists()
    @Published private(set) var all: [Playlist] = []
    /// Set from anywhere (a row, the player) to open the "Add to playlist" sheet for that track.
    @Published var pendingAdd: Track?

    private let key = "playlists"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([Playlist].self, from: data) {
            all = saved.map { p in
                var p = p
                p.tracks = p.tracks.filter { Search.isValid(id: $0.id) }
                return p
            }
        }
    }

    func playlist(_ id: UUID) -> Playlist? { all.first { $0.id == id } }

    @discardableResult
    func create(_ name: String, adding t: Track? = nil) -> UUID {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let p = Playlist(id: UUID(), name: clean.isEmpty ? "Untitled" : clean, tracks: t.map { [$0] } ?? [])
        all.insert(p, at: 0)
        save()
        return p.id
    }

    func add(_ t: Track, to id: UUID) {
        mutate(id) { if !$0.tracks.contains(where: { $0.id == t.id }) { $0.tracks.append(t) } }
    }

    func remove(at offsets: IndexSet, from id: UUID) { mutate(id) { $0.tracks.remove(atOffsets: offsets) } }
    func move(from: IndexSet, to: Int, in id: UUID) { mutate(id) { $0.tracks.move(fromOffsets: from, toOffset: to) } }

    func rename(_ id: UUID, to name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if !clean.isEmpty { mutate(id) { $0.name = clean } }
    }

    func delete(_ id: UUID) {
        all.removeAll { $0.id == id }
        save()
    }

    private func mutate(_ id: UUID, _ change: (inout Playlist) -> Void) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }
}

/// A 2×2 collage of the first four covers (or one cover, or a placeholder).
struct PlaylistCover: View {
    let playlist: Playlist
    var body: some View {
        let t = Array(playlist.tracks.prefix(4))
        Group {
            if t.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { Cover(track: t[0]); Cover(track: t[1]) }
                    HStack(spacing: 0) { Cover(track: t[2]); Cover(track: t[3]) }
                }
            } else if let first = t.first {
                Cover(track: first)
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.09))
                    Image(systemName: "music.note.list").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
    }
}

/// "Add to playlist" sheet.
struct PlaylistPicker: View {
    @ObservedObject private var store = Playlists.shared
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Button { creating = true } label: { Label("New playlist", systemImage: "plus") }
                ForEach(store.all) { p in
                    Button {
                        tap()
                        store.add(track, to: p.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistCover(playlist: p).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(p.name)
                            Spacer()
                            if p.tracks.contains(where: { $0.id == track.id }) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New playlist", isPresented: $creating) {
                TextField("Name", text: $name)
                Button("Create") { store.create(name, adding: track); name = ""; dismiss() }
                Button("Cancel", role: .cancel) { name = "" }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
