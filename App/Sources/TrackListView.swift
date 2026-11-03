import SwiftUI

/// Long-press menu for any song: playlist, play next, add to queue.
struct TrackMenu: ViewModifier {
    @EnvironmentObject var player: Player
    let track: Track
    var onRemove: (() -> Void)?
    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Play next", systemImage: "text.insert") { player.playNext(track) }
            Button("Add to queue", systemImage: "text.append") { player.addToQueue(track) }
            Button("Add to playlist", systemImage: "text.badge.plus") { Playlists.shared.pendingAdd = track }
            if let onRemove { Button("Remove download", systemImage: "trash", role: .destructive, action: onRemove) }
        }
    }
}

extension View {
    func trackMenu(_ t: Track, remove: (() -> Void)? = nil) -> some View { modifier(TrackMenu(track: t, onRemove: remove)) }
}

/// A plain list of songs with Play and Shuffle (used for Liked songs).
struct TrackListView: View {
    let title: String
    let tracks: [Track]
    /// (track to start with, the tracks to play after it)
    let onPlay: (Track, [Track]) -> Void

    var body: some View {
        List {
            VStack(spacing: 12) {
                Text(title).font(.system(size: 28, weight: .bold)).tracking(-0.6)
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")").font(.system(size: 14)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    action("Play", "play.fill") { tracks }
                    action("Shuffle", "shuffle") { tracks.shuffled() }
                }
                .disabled(tracks.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)

            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                Button { tap(); onPlay(t, Array(tracks[(i + 1)...])) } label: {
                    HStack(spacing: 12) {
                        Cover(track: t).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                            Text(t.duration.isEmpty ? t.channel : "\(t.channel) · \(t.duration)").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(PressStyle())
                .trackMenu(t)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func action(_ label: String, _ icon: String, order: @escaping () -> [Track]) -> some View {
        Button {
            let list = order()
            tap(.medium)
            if let first = list.first { onPlay(first, Array(list.dropFirst())) }
        } label: {
            Label(label, systemImage: icon).font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .frame(maxWidth: 170)
    }
}
