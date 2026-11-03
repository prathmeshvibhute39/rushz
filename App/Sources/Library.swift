import Foundation
import os

/// Offline copies of what you listen to: <dir>/<id>.m4a + <id>.json (shows up in the Files app).
/// The audio is saved exactly as YouTube serves it (no re-encode), so the copy is never worse than the stream.
/// Storage is yours to control: auto-save can be switched off, and an optional size cap drops the
/// least-recently-played songs first (songs that are in one of your playlists are never dropped automatically).
@MainActor
final class Library: ObservableObject {
    static let shared = Library()
    static let limitChoicesMB = [0, 500, 1000, 2000, 5000]  // 0 = no limit

    @Published private(set) var tracks: [Track] = []  // most recently saved/played first
    @Published private(set) var usedBytes: Int64 = 0
    @Published var autoSave: Bool { didSet { defaults.set(autoSave, forKey: "autoSave") } }
    @Published var limitMB: Int {
        didSet {
            defaults.set(limitMB, forKey: "limitMB")
            enforceLimit()
        }
    }

    /// Songs that must survive the size cap.
    var protectedIDs: @MainActor () -> Set<String> = { Set(Playlists.shared.all.flatMap(\.tracks).map(\.id)) }

    private let log = Logger(subsystem: "com.example.rushz", category: "library")
    private let dir: URL
    private let defaults: UserDefaults
    private var saving = Set<String>()

    init(directory: URL = URL.documentsDirectory.appending(path: "Rushz", directoryHint: .isDirectory), defaults: UserDefaults = .standard) {
        self.dir = directory
        self.defaults = defaults
        autoSave = defaults.object(forKey: "autoSave") as? Bool ?? true
        limitMB = defaults.integer(forKey: "limitMB")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var d = directory
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true  // re-downloadable media shouldn't fill iCloud backups
        try? d.setResourceValues(excluded)
        reload()
    }

    func localURL(_ id: String) -> URL? {
        guard Search.isValid(id: id) else { return nil }
        let f = dir.appending(path: "\(id).m4a")
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// The track after `t` in the library (wrapping), used as the offline "autoplay".
    func following(_ t: Track) -> Track? {
        guard tracks.count > 1, let i = tracks.firstIndex(where: { $0.id == t.id }) else { return tracks.first { $0.id != t.id } }
        return tracks[(i + 1) % tracks.count]
    }

    /// Marks a saved song as just played, so the size cap keeps it longest.
    func touch(_ id: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: dir.appending(path: "\(id).json").path)
        if i != 0 {
            var t = tracks
            t.insert(t.remove(at: i), at: 0)
            tracks = t
        }
    }

    func save(_ t: Track, from remote: URL) async {
        guard Search.isValid(id: t.id), localURL(t.id) == nil, saving.insert(t.id).inserted else { return }
        defer { saving.remove(t.id) }
        // Byte-for-byte copy of the stream (no re-encode). The caller has already waited out any preroll delay.
        let file = dir.appending(path: "\(t.id).m4a")
        do {
            var req = URLRequest(url: remote)
            req.setValue("bytes=0-", forHTTPHeaderField: "Range")  // media servers expect a ranged request
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                log.error("save \(t.id, privacy: .public) failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            try FileManager.default.moveItem(at: tmp, to: file)
            try add(t)
            log.info("saved \(t.id, privacy: .public)")
        } catch {
            try? FileManager.default.removeItem(at: file)
            log.error("save \(t.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Registers a track whose audio file is already in place (used by `save`, and by tests).
    func add(_ t: Track) throws {
        try JSONEncoder().encode(t).write(to: dir.appending(path: "\(t.id).json"))
        tracks.removeAll { $0.id == t.id }
        tracks.insert(t, at: 0)
        recount()
        enforceLimit()
    }

    func delete(_ t: Track) {
        for ext in ["m4a", "json"] { try? FileManager.default.removeItem(at: dir.appending(path: "\(t.id).\(ext)")) }
        tracks.removeAll { $0.id == t.id }
        recount()
    }

    func deleteAll() {
        for t in tracks { for ext in ["m4a", "json"] { try? FileManager.default.removeItem(at: dir.appending(path: "\(t.id).\(ext)")) } }
        tracks = []
        recount()
    }

    /// Drops least-recently-played songs (never playlist songs) until the library fits the cap.
    func enforceLimit() {
        guard limitMB > 0 else { return }
        let cap = Int64(limitMB) * 1_000_000
        let keep = protectedIDs()
        for t in Array(tracks.reversed()) where usedBytes > cap && !keep.contains(t.id) {
            delete(t)
            log.info("size cap: removed \(t.id, privacy: .public)")
        }
    }

    private func recount() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        usedBytes = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        tracks = files
            .filter { $0.pathExtension == "json" }
            .compactMap { json -> (Track, Date)? in
                guard let t = (try? Data(contentsOf: json)).flatMap({ try? JSONDecoder().decode(Track.self, from: $0) }),
                      Search.isValid(id: t.id), localURL(t.id) != nil else { return nil }
                let date = (try? json.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (t, date ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        recount()
    }
}
