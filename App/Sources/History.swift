import Foundation

/// What you listened to, most recent first. Stored locally on the phone only.
@MainActor
final class History: ObservableObject {
    static let shared = History()
    @Published private(set) var tracks: [Track] = []

    private let key = "recentTracks"
    private let limit = 40
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = saved.filter { Search.isValid(id: $0.id) }
        }
    }

    func record(_ t: Track) {
        guard !t.title.isEmpty else { return }
        tracks = Array(([t] + tracks.filter { $0.id != t.id }).prefix(limit))
        if let data = try? JSONEncoder().encode(tracks) { defaults.set(data, forKey: key) }
    }

    func clear() {
        tracks = []
        defaults.removeObject(forKey: key)
    }
}
