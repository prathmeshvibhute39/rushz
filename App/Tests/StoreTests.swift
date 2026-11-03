import XCTest
@testable import Rushz

/// Library (offline copies + size cap), playlists and history, each on throw-away storage.
@MainActor
final class StoreTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "rushz-tests-\(UUID().uuidString)")
        let name = "rushz-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)
        defaults.removePersistentDomain(forName: name)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func t(_ n: Int) -> Track { Track(id: String(format: "track%06d", n), title: "T\(n)", channel: "A", duration: "1:00") }

    /// A library with `count` fake songs of `bytes` bytes each (oldest = 1).
    private func library(count: Int, bytes: Int = 1_000_000) throws -> Library {
        let lib = Library(directory: dir, defaults: defaults)
        lib.protectedIDs = { [] }
        for n in 1...count {
            try Data(count: bytes).write(to: dir.appending(path: "\(t(n).id).m4a"))
            try lib.add(t(n))
            // distinct, increasing modification times so "oldest" is well defined
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + n))],
                                                  ofItemAtPath: dir.appending(path: "\(t(n).id).json").path)
        }
        return lib
    }

    // MARK: library

    func testAutoSaveDefaultsOnAndPersists() {
        let lib = Library(directory: dir, defaults: defaults)
        XCTAssertTrue(lib.autoSave)
        lib.autoSave = false
        XCTAssertFalse(Library(directory: dir, defaults: defaults).autoSave)
    }

    func testUsedBytesAndLocalURL() throws {
        let lib = try library(count: 3)
        XCTAssertGreaterThanOrEqual(lib.usedBytes, 3_000_000)
        XCTAssertNotNil(lib.localURL(t(1).id))
        XCTAssertNil(lib.localURL("../../../etc/passwd"), "ids are validated before touching the filesystem")
    }

    func testSizeCapRemovesLeastRecentlyPlayedFirst() throws {
        let lib = try library(count: 4)   // ~4 MB + metadata
        lib.limitMB = 500                  // cap far above usage: nothing happens
        XCTAssertEqual(lib.tracks.count, 4)
        lib.limitMB = 0
        // a 2.5 MB cap keeps about two songs; the two oldest (T1, T2) must go first
        lib.touch(t(3).id); lib.touch(t(4).id)
        let capMB = 2
        lib.limitMB = capMB
        XCTAssertLessThanOrEqual(lib.usedBytes, Int64(capMB) * 1_000_000)
        XCTAssertNil(lib.localURL(t(1).id))
        XCTAssertNil(lib.localURL(t(2).id))
        XCTAssertNotNil(lib.localURL(t(4).id), "the most recently played song survives")
    }

    func testSizeCapNeverRemovesPlaylistSongs() throws {
        let lib = try library(count: 3)
        lib.protectedIDs = { [self.t(1).id] }  // the oldest song is in a playlist
        lib.limitMB = 1
        XCTAssertNotNil(lib.localURL(t(1).id), "protected songs stay even over the cap")
    }

    func testTouchMovesSongToFront() throws {
        let lib = try library(count: 3)
        lib.touch(t(1).id)
        XCTAssertEqual(lib.tracks.first?.id, t(1).id)
    }

    func testDeleteAllClearsFilesAndCount() throws {
        let lib = try library(count: 3)
        lib.deleteAll()
        XCTAssertTrue(lib.tracks.isEmpty)
        XCTAssertEqual(lib.usedBytes, 0)
        XCTAssertNil(lib.localURL(t(1).id))
    }

    func testLibraryReloadsFromDisk() throws {
        _ = try library(count: 2)
        XCTAssertEqual(Library(directory: dir, defaults: defaults).tracks.count, 2)
    }

    func testFollowingWrapsAround() throws {
        let lib = try library(count: 3)
        let last = try XCTUnwrap(lib.tracks.last)
        XCTAssertEqual(lib.following(last)?.id, lib.tracks.first?.id)
    }

    // MARK: playlists

    func testPlaylistsCreateAddDedupeRenameDelete() {
        let store = Playlists(defaults: defaults)
        let id = store.create("  Road trip  ", adding: t(1))
        XCTAssertEqual(store.playlist(id)?.name, "Road trip")
        store.add(t(2), to: id)
        store.add(t(2), to: id)  // duplicate ignored
        XCTAssertEqual(store.playlist(id)?.tracks.map(\.title), ["T1", "T2"])
        store.rename(id, to: "Chill")
        store.rename(id, to: "   ")  // blank rename ignored
        XCTAssertEqual(store.playlist(id)?.name, "Chill")
        store.move(from: IndexSet(integer: 1), to: 0, in: id)
        XCTAssertEqual(store.playlist(id)?.tracks.map(\.title), ["T2", "T1"])
        store.remove(at: IndexSet(integer: 0), from: id)
        XCTAssertEqual(store.playlist(id)?.tracks.map(\.title), ["T1"])
        store.delete(id)
        XCTAssertNil(store.playlist(id))
    }

    func testPlaylistNameIsTrimmedAndCapped() {
        let store = Playlists(defaults: defaults)
        let id = store.create(String(repeating: "x", count: 200))
        XCTAssertEqual(store.playlist(id)?.name.count, 60)
        XCTAssertEqual(store.playlist(store.create("   "))?.name, "Untitled")
    }

    func testPlaylistsPersistAndDropInvalidIDs() throws {
        let store = Playlists(defaults: defaults)
        let id = store.create("Mix", adding: t(1))
        let bad = Track(id: "../evil", title: "x", channel: "", duration: "")
        var all = store.all
        all[0].tracks.append(bad)
        defaults.set(try JSONEncoder().encode(all), forKey: "playlists")
        let reloaded = Playlists(defaults: defaults)
        XCTAssertEqual(reloaded.playlist(id)?.tracks.map(\.id), [t(1).id], "tracks with malformed ids are dropped on load")
    }

    // MARK: history

    func testHistoryMostRecentFirstNoDuplicatesCapped() {
        let h = History(defaults: defaults)
        h.record(t(1)); h.record(t(2)); h.record(t(1))
        XCTAssertEqual(h.tracks.map(\.title), ["T1", "T2"])
        for n in 3...60 { h.record(t(n)) }
        XCTAssertEqual(h.tracks.count, 40)
        XCTAssertEqual(History(defaults: defaults).tracks.count, 40, "persists")
        h.clear()
        XCTAssertTrue(h.tracks.isEmpty)
        XCTAssertTrue(History(defaults: defaults).tracks.isEmpty)
    }

    func testHistoryIgnoresUntitledTracks() {
        let h = History(defaults: defaults)
        h.record(Track(id: "track000001", title: "", channel: "", duration: ""))
        XCTAssertTrue(h.tracks.isEmpty)
    }
}
