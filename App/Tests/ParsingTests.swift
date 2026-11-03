import XCTest
@testable import Rushz

/// Parser tests run against trimmed REAL YouTube Music responses (Tests/Fixtures), so a change in YouTube's
/// response shape fails here instead of silently emptying the app.
final class ParsingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Any {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "missing fixture \(name)")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    // MARK: ids and images

    func testIDValidation() {
        XCTAssertTrue(Search.isValid(id: "dQw4w9WgXcQ"))
        XCTAssertTrue(Search.isValid(id: "a-b_c-d_e-f"))
        XCTAssertFalse(Search.isValid(id: "short"))
        XCTAssertFalse(Search.isValid(id: "dQw4w9WgXcQ1"))
        XCTAssertFalse(Search.isValid(id: "dQw4w9WgXc/"))
        XCTAssertFalse(Search.isValid(id: "../../etc/pw"))
        XCTAssertFalse(Search.isValid(id: ""))
    }

    func testArtOnlyFromGoogleImageHostsAndUpscaled() {
        func art(_ url: String) -> String? { Search.art([["url": url, "width": 60, "height": 60]]) }
        XCTAssertEqual(art("https://lh3.googleusercontent.com/x=w60-h60-l90-rj"), "https://lh3.googleusercontent.com/x=w544-h544-l90-rj")
        XCTAssertNotNil(art("https://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg"))
        XCTAssertNil(art("http://lh3.googleusercontent.com/x=w60-h60"), "plain http is rejected")
        XCTAssertNil(art("https://evil.example.com/x.jpg"), "other hosts are rejected")
        XCTAssertNil(art("not a url"))
        XCTAssertNil(Search.art(nil))
    }

    func testTrackDecodesOldSavedDataWithoutArt() throws {
        let old = #"{"id":"dQw4w9WgXcQ","title":"T","channel":"C","duration":"3:00"}"#.data(using: .utf8)!
        let t = try JSONDecoder().decode(Track.self, from: old)
        XCTAssertNil(t.art)
        XCTAssertEqual(t.thumbnail?.host, "i.ytimg.com")
    }

    // MARK: search

    func testSearchSongsFixture() throws {
        let songs = Search.songs(in: try fixture("search_songs"))
        XCTAssertEqual(songs.count, 3)
        let first = try XCTUnwrap(songs.first)
        XCTAssertEqual(first.id, "v2TsWj3wxHM")
        XCTAssertEqual(first.title, "Darmiyaan")
        XCTAssertEqual(first.channel, "Rekha Bhardwaj, Raghav Kaushik & Amrita Saluja")
        XCTAssertEqual(first.duration, "4:31")
        XCTAssertTrue(first.isSquareArt)
        XCTAssertTrue(first.art?.contains("=w544-h544") ?? false)
        XCTAssertEqual(songs[1].channel, "Shafqat Amanat Ali | Clinton Cerejo")
        XCTAssertTrue(songs.allSatisfy { Search.isValid(id: $0.id) })
    }

    func testSearchOnGarbageReturnsNothing() {
        XCTAssertTrue(Search.songs(in: ["unexpected": [1, 2, 3]]).isEmpty)
        XCTAssertTrue(Search.songs(in: "nope").isEmpty)
    }

    // MARK: radio queue

    func testQueueFixture() throws {
        let tracks = Search.queueTracks(in: try fixture("next_queue"))
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks[0].id, "GjpAu0fEd_w")
        XCTAssertTrue(tracks[0].title.hasPrefix("Tulasi"))
        XCTAssertEqual(tracks[0].channel, "DJ SK TALCHER")
        XCTAssertEqual(tracks[0].duration, "3:39")
        XCTAssertFalse(tracks[0].isSquareArt, "video frames are not square art")
        XCTAssertTrue(tracks.allSatisfy { Search.isValid(id: $0.id) })
    }

    // MARK: home feed

    func testHomeFeedFixture() throws {
        let shelves = Feed.shelves(in: try fixture("home_feed"))
        XCTAssertEqual(shelves.map(\.title), ["Quick picks", "Listen again"], "the playlists-only shelf is skipped")
        XCTAssertEqual(shelves[0].tracks.count, 3)
        XCTAssertTrue(shelves[0].tracks.allSatisfy { Search.isValid(id: $0.id) })
    }

    func testListenAgainCardsKeepSongsAndDropTypeLabel() throws {
        let again = try XCTUnwrap(Feed.shelves(in: try fixture("home_feed")).last)
        XCTAssertEqual(again.tracks.count, 2, "the album card has no watchEndpoint and is dropped")
        XCTAssertEqual(again.tracks[0].channel, "Some Artist", "the leading 'Song' label is not the artist")
        XCTAssertEqual(again.tracks[1].channel, "Other Artist")
        XCTAssertTrue(again.tracks[0].isSquareArt)
    }

    func testHomeFeedOnGarbageIsEmpty() {
        XCTAssertTrue(Feed.shelves(in: ["contents": 5]).isEmpty)
    }
}
