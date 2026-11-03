import Foundation

struct Shelf: Identifiable, Codable, Equatable {
    var id: String { title }
    let title: String
    let tracks: [Track]
}

/// Your YouTube Music home shelves and liked songs (read-only: nothing here writes to your account).
/// Cached on the phone so the home screen fills instantly; wiped on sign-out.
@MainActor
final class Feed: ObservableObject {
    static let shared = Feed()
    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var liked: [Track] = []
    @Published private(set) var isLoading = false

    private struct Snapshot: Codable { let shelves: [Shelf]; let liked: [Track] }
    private let file: URL

    init(file: URL = URL.cachesDirectory.appending(path: "feed.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            shelves = s.shelves
            liked = s.liked
        }
    }

    func refresh() async {
        guard Account.shared.isSignedIn, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let home = try? Search.browse("FEmusic_home")
        async let likes = try? Search.browse("VLLM")  // the "Liked music" playlist
        let (h, l) = await (home, likes)
        if let h { shelves = Self.shelves(in: h) }
        if let l { liked = Search.songs(in: l) }
        if let data = try? JSONEncoder().encode(Snapshot(shelves: shelves, liked: liked)) { try? data.write(to: file) }
    }

    func clear() {
        shelves = []
        liked = []
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - parsing

    private nonisolated static let carouselKeys = ["musicCarouselShelfRenderer", "musicImmersiveCarouselShelfRenderer"]

    /// Home shelves in page order. Shelves of albums or playlists (no playable songs) are skipped.
    nonisolated static func shelves(in json: Any) -> [Shelf] {
        var node: Any? = json
        for key in ["contents", "singleColumnBrowseResultsRenderer", "tabs"] { node = (node as? [String: Any])?[key] }
        let sections = ((((node as? [Any])?.first as? [String: Any])?["tabRenderer"] as? [String: Any])?["content"] as? [String: Any])
            .flatMap { ($0["sectionListRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] } ?? []
        return sections.compactMap { section in
            guard let key = carouselKeys.first(where: { section[$0] != nil }), let shelf = section[key] as? [String: Any] else { return nil }
            let header = (shelf["header"] as? [String: Any])?.values.first as? [String: Any]
            guard let title = Search.texts(header?["title"]).first else { return nil }
            let tracks = (shelf["contents"] as? [[String: Any]] ?? []).compactMap { item -> Track? in
                if let r = item["musicResponsiveListItemRenderer"] as? [String: Any] { return Search.listTrack(r) }
                if let r = item["musicTwoRowItemRenderer"] as? [String: Any] { return twoRowTrack(r) }
                return nil
            }
            return tracks.count >= 2 ? Shelf(title: title, tracks: tracks) : nil
        }
    }

    /// Cards in "Listen again"-style shelves: songs carry a watchEndpoint (albums and playlists carry a browseEndpoint).
    private nonisolated static func twoRowTrack(_ r: [String: Any]) -> Track? {
        guard let id = ((r["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String,
              Search.isValid(id: id), let title = Search.texts(r["title"]).first else { return nil }
        var g = Search.groups(Search.texts(r["subtitle"]))
        if let first = g.first, ["Song", "Video"].contains(first), g.count > 1 { g.removeFirst() }  // leading type label
        let thumb = ((r["thumbnailRenderer"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any]
        return Track(id: id, title: title, channel: g.first ?? "", duration: "", art: Search.art(thumb?["thumbnails"]))
    }
}
