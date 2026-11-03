import SwiftUI

/// Minimal Spotify-style home: greeting, a quick grid of the latest plays, then shelves.
struct HomeView: View {
    @ObservedObject private var history = History.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var playlists = Playlists.shared
    @ObservedObject private var feed = Feed.shared
    /// (track to start with, tracks to play after it)
    let onPlay: (Track, [Track]) -> Void
    @State private var creating = false
    @State private var newName = ""

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text(greeting)
                    .font(.system(size: 32, weight: .bold)).tracking(-0.7)
                    .padding(.top, 4)
                if history.tracks.isEmpty && library.tracks.isEmpty && feed.shelves.isEmpty {
                    Text("Search for a song. What you play shows up here.")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                }
                if !history.tracks.isEmpty { grid(Array(history.tracks.prefix(6))) }
                likedTile
                playlistShelf
                ForEach(feed.shelves.prefix(5)) { s in shelf(s.title, Array(s.tracks.prefix(14))) }
                if history.tracks.count > 6 { shelf("Recently played", Array(history.tracks.dropFirst(6).prefix(14))) }
                if !library.tracks.isEmpty { shelf("Downloaded", library.tracks, removable: true) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    // MARK: - liked songs (from your account)

    @ViewBuilder private var likedTile: some View {
        if !feed.liked.isEmpty {
            NavigationLink {
                TrackListView(title: "Liked songs", tracks: feed.liked, onPlay: onPlay)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "heart.fill").font(.system(size: 22)).foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Liked songs").font(.system(size: 17, weight: .semibold))
                        Text("\(feed.liked.count) songs from your account").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(PressStyle())
        }
    }

    // MARK: - playlists

    private var playlistShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your playlists").font(.system(size: 22, weight: .bold)).tracking(-0.4)
                Spacer()
                Button { creating = true } label: { Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).frame(width: 36, height: 36) }
                    .buttonStyle(PressStyle())
            }
            if playlists.all.isEmpty {
                Text("Press and hold any song, then “Add to playlist”.").font(.system(size: 14)).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(playlists.all) { p in
                            NavigationLink(value: p) {
                                VStack(alignment: .leading, spacing: 8) {
                                    PlaylistCover(playlist: p).frame(width: 140, height: 140)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).frame(width: 140, alignment: .leading)
                                }
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .alert("New playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { playlists.create(newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    // MARK: - grid (the latest six plays, two columns)

    private func grid(_ items: [Track]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(items) { t in
                Button { tap(); onPlay(t, []) } label: {
                    HStack(spacing: 10) {
                        Cover(track: t).frame(width: 54, height: 54)
                        Text(t.title)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 54)
                    .background(.white.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .trackMenu(t)
            }
        }
    }

    // MARK: - shelf (horizontal row of covers)

    private func shelf(_ title: String, _ items: [Track], removable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(items) { t in
                        Button { tap(); onPlay(t, []) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Cover(track: t).frame(width: 140, height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(t.title)
                                    .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(width: 140, alignment: .leading)
                            }
                        }
                        .buttonStyle(PressStyle())
                        .trackMenu(t, remove: removable ? { library.delete(t) } : nil)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}
