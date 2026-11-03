import Foundation

struct LyricLine: Equatable, Codable {
    let time: Double?  // seconds; nil for plain (untimed) lyrics
    let text: String
}

struct LyricsResult: Equatable, Codable {
    let lines: [LyricLine]
    var isSynced: Bool { lines.contains { $0.time != nil } }

    /// Index of the line being sung at `t` (the last line whose timestamp has passed).
    func lineIndex(at t: Double) -> Int? {
        guard isSynced else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if let lt = lines[mid].time, lt <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

/// Lyrics from LRCLIB (free, no key). Looked up only when you open the lyrics view, and cached on the phone.
enum Lyrics {
    private static let base = URL(string: "https://lrclib.net/api")!
    private static let cacheDir = URL.cachesDirectory.appending(path: "Lyrics", directoryHint: .isDirectory)

    static func fetch(for track: Track, duration: Double) async -> LyricsResult? {
        if let cached = cached(track.id) { return cached }
        let artist = primaryArtist(track.channel)
        var found: LyricsResult?
        for title in [cleanTitle(track.title, artist: artist), track.title].uniqued() where found == nil {
            found = await get(title: title, artist: artist, duration: duration)
            if found == nil { found = await search(title: title, artist: artist, duration: duration) }
        }
        if let found { store(found, id: track.id) }
        return found
    }

    // MARK: - LRCLIB

    private struct Entry: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private static func result(_ e: Entry) -> LyricsResult? {
        if let s = e.syncedLyrics, case let lines = parseLRC(s), !lines.isEmpty { return LyricsResult(lines: lines) }
        if let p = e.plainLyrics, case let lines = parsePlain(p), !lines.isEmpty { return LyricsResult(lines: lines) }
        return nil
    }

    private static func request(_ path: String, _ query: [String: String]) async -> Data? {
        var c = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        c.queryItems = query.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url, url.host == "lrclib.net" else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Rushz/1.0 (personal iOS player)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func get(title: String, artist: String, duration: Double) async -> LyricsResult? {
        let q = ["track_name": title, "artist_name": artist, "duration": duration > 0 ? String(Int(duration.rounded())) : ""]
        guard let data = await request("get", q), let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return result(e)
    }

    /// Fallback: fuzzy search; prefer a timed match whose length is within 3 s of the song.
    private static func search(title: String, artist: String, duration: Double) async -> LyricsResult? {
        guard let data = await request("search", ["track_name": title, "artist_name": artist]),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        let close = entries.filter { duration <= 0 || abs(($0.duration ?? duration) - duration) <= 3 }
        let pool = close.isEmpty ? entries : close
        let best = pool.first { $0.syncedLyrics?.isEmpty == false } ?? pool.first { $0.plainLyrics?.isEmpty == false }
        return best.flatMap(result)
    }

    // MARK: - parsing

    /// "[01:23.45]text" lines (several timestamps per line allowed); metadata tags like [ar:..] are ignored.
    static func parseLRC(_ text: String) -> [LyricLine] {
        let stamp = /\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]/
        var out: [LyricLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = Substring(raw)
            var times: [Double] = []
            while let m = line.prefixMatch(of: stamp) {
                times.append((Double(m.1) ?? 0) * 60 + (Double(m.2) ?? 0))
                line = line[m.range.upperBound...]
            }
            let body = line.trimmingCharacters(in: .whitespaces)
            for t in times { out.append(LyricLine(time: t, text: body)) }
        }
        return out.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }

    static func parsePlain(_ text: String) -> [LyricLine] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { LyricLine(time: nil, text: $0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Video-style titles lose their decorations: "Adele - Hello (Official Music Video)" → "Hello",
    /// "Darmiyaan (Full Video) | Musafir Cafe | …" → "Darmiyaan". "(feat. …)" is kept: lyric databases keep it too.
    static func cleanTitle(_ title: String, artist: String) -> String {
        var t = (title.components(separatedBy: " | ").first ?? title).trimmingCharacters(in: .whitespaces)
        if !artist.isEmpty, let r = t.range(of: artist + " - ", options: [.caseInsensitive, .anchored]) { t.removeSubrange(r) }
        let decoration = /\s*[\(\[][^\)\]]*\b(official|video|audio|lyrics?|visuali[sz]er|remaster(?:ed)?|hd|4k|full song|music video)\b[^\)\]]*[\)\]]/.ignoresCase()
        t = t.replacing(decoration, with: "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t
    }

    /// "Rekha Bhardwaj, Raghav Kaushik & Amrita Saluja" → "Rekha Bhardwaj"
    static func primaryArtist(_ s: String) -> String {
        let seps = [", ", " & ", " | ", " x ", " feat.", " ft.", " feat ", " ft "]
        var cut = s.endIndex
        for sep in seps { if let r = s.range(of: sep, options: .caseInsensitive), r.lowerBound < cut { cut = r.lowerBound } }
        return String(s[..<cut]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - cache

    private static func cached(_ id: String) -> LyricsResult? {
        guard Search.isValid(id: id) else { return nil }
        return (try? Data(contentsOf: cacheDir.appending(path: "\(id).json"))).flatMap { try? JSONDecoder().decode(LyricsResult.self, from: $0) }
    }

    private static func store(_ r: LyricsResult, id: String) {
        guard Search.isValid(id: id) else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(r).write(to: cacheDir.appending(path: "\(id).json"))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
