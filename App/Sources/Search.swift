import Foundation

struct Track: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let channel: String  // artist(s)
    let duration: String
    var art: String? = nil  // album art URL from YouTube Music (older saved tracks have none)

    var isSquareArt: Bool { art?.contains("googleusercontent.com") ?? false }
    var thumbnail: URL? { URL(string: art ?? "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
}

/// YouTube Music's own search and radio, so results are songs with real artists and album art.
enum Search {
    private static let idPattern = /^[A-Za-z0-9_-]{11}$/
    private static let songsFilter = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"  // search "Songs" tab only

    /// Everything from YouTube is untrusted: only well-formed 11-char IDs ever reach a URL.
    static func isValid(id: String) -> Bool { id.wholeMatch(of: idPattern) != nil }

    static func run(_ query: String) async throws -> [Track] {
        songs(in: try await post("search", ["query": query, "params": songsFilter]))
    }

    /// Songs in a search / playlist response.
    static func songs(in json: Any) -> [Track] { collect(json, "musicResponsiveListItemRenderer", listTrack) }

    /// Tracks of a radio queue (`next` response), current song first.
    static func queueTracks(in json: Any) -> [Track] { collect(json, "playlistPanelVideoRenderer", panelTrack) }

    /// A YouTube Music page (home feed, liked songs…). Personalised when signed in.
    static func browse(_ id: String) async throws -> Any { try await post("browse", ["browseId": id]) }

    /// YouTube's own autoplay pick: the track after `id` in its radio queue.
    // ponytail: only the next pick, not the whole queue; use `queue(_:)` if you want a visible "Up next" list.
    static func upNext(after id: String) async throws -> Track? {
        guard isValid(id: id) else { return nil }
        return try await queue(id).first { $0.id != id }
    }

    /// Title, artist and art of one song (the first entry of its own queue).
    static func details(id: String) async -> Track? {
        guard isValid(id: id) else { return nil }
        return try? await queue(id).first { $0.id == id }
    }

    private static func queue(_ id: String) async throws -> [Track] {
        let json = try await post("next", ["videoId": id, "playlistId": "RDAMVM" + id, "isAudioOnly": true])
        return queueTracks(in: json)
    }

    // MARK: - request

    static func post(_ endpoint: String, _ fields: [String: Any]) async throws -> Any {
        let url = URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.httpShouldHandleCookies = false  // cookies are attached explicitly, and only when signed in
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        for (k, v) in await Account.shared.headers(for: url) { req.setValue(v, forHTTPHeaderField: k) }
        var body = fields
        body["context"] = ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20261027.10.00", "hl": "en"]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - parsing

    /// Walks the response tree and collects every renderer with the given key.
    static func collect(_ node: Any, _ key: String, _ make: ([String: Any]) -> Track?) -> [Track] {
        if let d = node as? [String: Any] {
            if let v = d[key] as? [String: Any] { return make(v).map { [$0] } ?? [] }
            return d.values.flatMap { collect($0, key, make) }
        }
        if let a = node as? [Any] { return a.flatMap { collect($0, key, make) } }
        return []
    }

    static func texts(_ node: Any?) -> [String] {
        ((node as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
    }

    /// "Artist, Artist • Album • 4:31" arrives as runs; split them at the " • " separators.
    static func groups(_ runs: [String]) -> [String] {
        var out = [""]
        for r in runs { if r == " • " { out.append("") } else { out[out.count - 1] += r } }
        return out
    }

    /// Largest thumbnail, upscaled for album art; only images from Google's own image hosts are accepted.
    static func art(_ list: Any?) -> String? {
        guard let s = ((list as? [[String: Any]])?.last)?["url"] as? String, let u = URL(string: s), u.scheme == "https",
              let host = u.host, host.hasSuffix("googleusercontent.com") || host.hasSuffix("ytimg.com") else { return nil }
        return s.replacing(/=w\d+-h\d+/, with: "=w544-h544")
    }

    static func listTrack(_ r: [String: Any]) -> Track? {
        guard let id = (r["playlistItemData"] as? [String: Any])?["videoId"] as? String, isValid(id: id),
              let cols = r["flexColumns"] as? [[String: Any]], cols.count > 1 else { return nil }
        func runs(_ c: [String: Any]) -> [String] { texts((c["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"]) }
        guard let title = runs(cols[0]).first else { return nil }
        let g = groups(runs(cols[1]))
        let fixed = ((r["fixedColumns"] as? [[String: Any]])?.first?["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any])?["text"]
        let duration = g.last.flatMap { $0.contains(":") ? $0 : nil } ?? texts(fixed).first ?? ""
        let thumb = ((r["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any]
        return Track(id: id, title: title, channel: g.first ?? "", duration: duration, art: art(thumb?["thumbnails"]))
    }

    private static func panelTrack(_ r: [String: Any]) -> Track? {
        guard let id = r["videoId"] as? String, isValid(id: id) else { return nil }
        let title = texts(r["title"]).joined()
        guard !title.isEmpty else { return nil }
        return Track(id: id, title: title, channel: groups(texts(r["longBylineText"])).first ?? "",
                     duration: texts(r["lengthText"]).joined(),
                     art: art((r["thumbnail"] as? [String: Any])?["thumbnails"]))
    }
}
