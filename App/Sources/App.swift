import SwiftUI

@main
struct RushzApp: App {
    @StateObject private var player = Player()
    @StateObject private var account = Account.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(account)
                .preferredColorScheme(.dark)
                .task {
                    account.install()
                    await account.refresh()
                    await Feed.shared.refresh()
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var account: Account
    @ObservedObject private var library = Library.shared
    @ObservedObject private var playlists = Playlists.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var error: String?
    @State private var searching = false
    @State private var expanded = false
    @State private var dismissProgress: CGFloat = 0
    @State private var showAccount = false

    private var spring: Animation? { reduceMotion ? nil : Motion.smooth }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            home
                .scaleEffect(expanded ? 0.94 + 0.06 * dismissProgress : 1)  // pushed back, and returning as the player is dragged away
                .opacity(expanded ? 0.45 + 0.55 * dismissProgress : 1)
                .allowsHitTesting(!expanded)
            if expanded {
                NowPlayingView(close: {
                    var t = Transaction()
                    t.disablesAnimations = true  // the player already slid off-screen by itself
                    withTransaction(t) { expanded = false }
                    dismissProgress = 0
                }, dismissProgress: $dismissProgress)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
            }
        }
        .sheet(isPresented: $showAccount) { SettingsSheet() }
        .onChange(of: account.needsAttention) { _, needs in
            if needs { showAccount = true; account.needsAttention = false }
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn { Task { await Feed.shared.refresh() } }
        }
        .sheet(item: $playlists.pendingAdd) { PlaylistPicker(track: $0) }
        #if DEBUG
        .task {  // RUSHZ_OPEN=settings|player|queue|lyrics opens that screen (for screenshots)
            let open = ProcessInfo.processInfo.environment["RUSHZ_OPEN"] ?? ""
            if open == "settings" { showAccount = true }
            else if ["player", "queue", "lyrics"].contains(open) { try? await Task.sleep(for: .seconds(14)); expanded = true }
        }
        #endif
    }

    private func play(_ t: Track, then queue: [Track] = []) {
        player.start(t, then: queue)
        withAnimation(spring) { expanded = true }
    }

    private var home: some View {
        NavigationStack {
            Group {
                if results.isEmpty && !searching && error == nil {
                    HomeView { play($0, then: $1) }
                } else {
                    List(results) { trackButton($0) }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .overlay {
                            if searching { ProgressView() }
                            else if let error { Text(error).foregroundStyle(.red).padding() }
                        }
                }
            }
            .searchable(text: $query, prompt: "Search")
            .onSubmit(of: .search) { Task { await run() } }
            .onChange(of: query) { if query.isEmpty { results = []; error = nil } }
            .navigationTitle("Rushz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAccount = true } label: {
                        Image(systemName: account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    }
                }
            }
            .navigationDestination(for: Playlist.self) { p in
                PlaylistView(id: p.id) { play($0, then: $1) }
            }
            .safeAreaInset(edge: .bottom) { if player.current != nil { miniPlayer } }
        }
    }

    private func trackButton(_ t: Track) -> some View {
        Button {
            tap()
            play(t)
        } label: { row(t) }
        .buttonStyle(PressStyle())
        .trackMenu(t)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func row(_ t: Track) -> some View {
        let active = t.id == player.current?.id
        return HStack(spacing: 14) {
            Cover(track: t).frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    .foregroundStyle(active ? Color.accentColor : .white)
                HStack(spacing: 4) {
                    if library.localURL(t.id) != nil { Image(systemName: "arrow.down.circle.fill").font(.system(size: 11)) }
                    Text(t.duration.isEmpty ? t.channel : "\(t.channel) · \(t.duration)").lineLimit(1)
                }
                .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var miniPlayer: some View {
        HStack(spacing: 12) {
            if let t = player.current {
                Cover(track: t).frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(player.status ?? t.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            Spacer()
            Button { tap(.medium); player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 22)).frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            Button { tap(); player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 20)).frame(width: 36, height: 36) }
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.white)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)  // same margin as the content above it
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(spring) { expanded = true } }
    }

    private func run() async {
        searching = true
        defer { searching = false }
        do { results = try await Search.run(query); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
