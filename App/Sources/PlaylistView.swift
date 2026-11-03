import SwiftUI

struct PlaylistView: View {
    @ObservedObject private var store = Playlists.shared
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    /// (track to start with, the tracks to play after it)
    let onPlay: (Track, [Track]) -> Void
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var name = ""

    var body: some View {
        if let p = store.playlist(id) {
            List {
                header(p)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                ForEach(Array(p.tracks.enumerated()), id: \.element.id) { i, t in
                    Button { tap(); onPlay(t, Array(p.tracks[(i + 1)...])) } label: {
                        HStack(spacing: 12) {
                            Cover(track: t).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                                Text(t.channel).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(PressStyle())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .onDelete { store.remove(at: $0, from: id) }
                .onMove { store.move(from: $0, to: $1, in: id) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Rename", systemImage: "pencil") { name = p.name; renaming = true }
                        Button("Delete playlist", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert("Rename playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Save") { store.rename(id, to: name) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(p.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete playlist", role: .destructive) { store.delete(id); dismiss() }
            } message: { Text("The songs themselves are not deleted.") }
        }
    }

    private func header(_ p: Playlist) -> some View {
        VStack(spacing: 14) {
            PlaylistCover(playlist: p).frame(width: 190, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            Text(p.name).font(.system(size: 26, weight: .bold)).tracking(-0.5).multilineTextAlignment(.center)
            Text("\(p.tracks.count) song\(p.tracks.count == 1 ? "" : "s")").font(.system(size: 14)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                playButton("Play", "play.fill") { p.tracks }
                playButton("Shuffle", "shuffle") { p.tracks.shuffled() }
            }
            .disabled(p.tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func playButton(_ title: String, _ icon: String, order: @escaping () -> [Track]) -> some View {
        Button {
            let list = order()
            tap(.medium)
            if let first = list.first { onPlay(first, Array(list.dropFirst())) }
        } label: {
            Label(title, systemImage: icon).font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .frame(maxWidth: 170)
    }
}
