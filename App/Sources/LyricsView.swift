import SwiftUI

/// Synced lyrics follow the song (tap a line to jump there); songs with only plain lyrics just scroll.
struct LyricsView: View {
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var result: LyricsResult?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .navigationTitle(player.current?.title ?? "Lyrics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .task(id: player.current?.id) { await load() }
    }

    @ViewBuilder private var content: some View {
        if loading {
            Spacer(); ProgressView(); Spacer()
        } else if let r = result {
            let active = r.lineIndex(at: player.time + 0.25)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(r.lines.enumerated()), id: \.offset) { i, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: r.isSynced ? 28 : 20, weight: .bold)).tracking(-0.3)
                                .foregroundStyle(.white.opacity(!r.isSynced || i == active ? 1 : 0.32))
                                .animation(Motion.snappy, value: active)
                                .id(i)
                                .onTapGesture { if let t = line.time { tap(); player.seek(to: t) } }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 40)  // same inset as the title above
                }
                .onChange(of: active) { _, new in
                    if let new { withAnimation(Motion.smooth) { proxy.scrollTo(new, anchor: .center) } }
                }
            }
        } else {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "text.quote").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("No lyrics found").font(.system(size: 17, weight: .semibold))
                Text("The free lyrics database is missing many regional songs.").font(.system(size: 14)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            Spacer()
        }
    }

    private func load() async {
        guard let t = player.current else { return }
        loading = true
        result = nil
        let length = player.duration > 0 ? player.duration : AudioLength.seconds(ofClock: t.duration) ?? 0
        let found = await Lyrics.fetch(for: t, duration: length)
        if player.current?.id == t.id { result = found }  // ignore a slow answer for a song that already changed
        loading = false
    }
}
