import SwiftUI

/// What's playing, what's queued (drag to reorder, swipe to remove, tap to jump), and what you already played.
struct QueueView: View {
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let t = player.current {
                    Section("Now playing") { row(t, highlighted: true) }
                }
                Section {
                    if player.queue.upcoming.isEmpty {
                        Text("Nothing queued. YouTube's autoplay picks what comes next.")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(player.queue.upcoming.enumerated()), id: \.offset) { i, t in
                        Button { tap(); player.jump(toUpcoming: i) } label: { row(t) }
                            .buttonStyle(PressStyle())
                    }
                    .onDelete { player.removeUpcoming(at: $0) }
                    .onMove { player.moveUpcoming(from: $0, to: $1) }
                    if !player.queue.upcoming.isEmpty {
                        Button("Clear queue", role: .destructive) { player.removeUpcoming(at: IndexSet(0..<player.queue.upcoming.count)) }
                    }
                } header: {
                    Text("Next in queue")
                } footer: {
                    if !player.queue.upcoming.isEmpty { Text("Then YouTube's autoplay takes over.") }
                }
                if !player.queue.played.isEmpty {
                    Section("Played") {
                        ForEach(Array(player.queue.played.reversed().enumerated()), id: \.offset) { _, t in row(t).opacity(0.6) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private func row(_ t: Track, highlighted: Bool = false) -> some View {
        HStack(spacing: 12) {
            Cover(track: t).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(highlighted ? Color.accentColor : .white)
                Text(t.channel).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
