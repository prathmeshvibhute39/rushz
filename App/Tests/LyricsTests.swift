import XCTest
@testable import Rushz

final class LyricsTests: XCTestCase {
    func testParseLRCReadsTimestampsAndText() {
        let lines = Lyrics.parseLRC("[00:06.22]Hello, it's me\n[00:11.84]I was wondering\n[01:02.5]Late line")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].text, "Hello, it's me")
        XCTAssertEqual(try XCTUnwrap(lines[0].time), 6.22, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(lines[2].time), 62.5, accuracy: 0.001)
    }

    func testParseLRCIgnoresMetadataTags() {
        let lines = Lyrics.parseLRC("[ar:Adele]\n[ti:Hello]\n[00:01.00]Only this")
        XCTAssertEqual(lines.map(\.text), ["Only this"])
    }

    func testParseLRCExpandsRepeatedTimestampsAndSorts() {
        let lines = Lyrics.parseLRC("[00:30.00][00:10.00]Chorus\n[00:20.00]Verse")
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Verse", "Chorus"])
        XCTAssertEqual(lines.compactMap(\.time), [10, 20, 30])
    }

    func testParseLRCKeepsInstrumentalGapsAsEmptyLines() {
        let lines = Lyrics.parseLRC("[00:05.00]\n[00:09.00]Sing")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "")
    }

    func testPlainLyricsHaveNoTimes() {
        let lines = Lyrics.parsePlain("one\ntwo\n\nthree")
        XCTAssertEqual(lines.map(\.text), ["one", "two", "", "three"])
        XCTAssertTrue(lines.allSatisfy { $0.time == nil })
        XCTAssertFalse(LyricsResult(lines: lines).isSynced)
    }

    func testLineIndexFollowsPlaybackTime() {
        let r = LyricsResult(lines: Lyrics.parseLRC("[00:05.00]a\n[00:10.00]b\n[00:20.00]c"))
        XCTAssertTrue(r.isSynced)
        XCTAssertNil(r.lineIndex(at: 1), "before the first line nothing is highlighted")
        XCTAssertEqual(r.lineIndex(at: 5), 0)
        XCTAssertEqual(r.lineIndex(at: 12), 1)
        XCTAssertEqual(r.lineIndex(at: 999), 2)
    }

    func testPlainLyricsNeverHighlightALine() {
        XCTAssertNil(LyricsResult(lines: Lyrics.parsePlain("a\nb")).lineIndex(at: 10))
    }

    func testPrimaryArtist() {
        XCTAssertEqual(Lyrics.primaryArtist("Rekha Bhardwaj, Raghav Kaushik & Amrita Saluja"), "Rekha Bhardwaj")
        XCTAssertEqual(Lyrics.primaryArtist("Shafqat Amanat Ali | Clinton Cerejo"), "Shafqat Amanat Ali")
        XCTAssertEqual(Lyrics.primaryArtist("Adele"), "Adele")
        XCTAssertEqual(Lyrics.primaryArtist("Mark Ronson feat. Bruno Mars"), "Mark Ronson")
        XCTAssertEqual(Lyrics.primaryArtist(""), "")
    }

    func testClockStringToSeconds() {
        XCTAssertEqual(AudioLength.seconds(ofClock: "4:31"), 271)
        XCTAssertEqual(AudioLength.seconds(ofClock: "1:02:03"), 3723)
        XCTAssertNil(AudioLength.seconds(ofClock: ""))
        XCTAssertNil(AudioLength.seconds(ofClock: "abc"))
        XCTAssertNil(AudioLength.seconds(ofClock: "0:00"))
    }

    func testStreamDurationParam() {
        XCTAssertEqual(AudioLength.seconds(ofStream: URL(string: "https://x.googlevideo.com/videoplayback?id=a&dur=366.841&c=TVHTML5")!), 366.841)
        XCTAssertNil(AudioLength.seconds(ofStream: URL(string: "https://x.googlevideo.com/videoplayback?id=a")!))
        XCTAssertNil(AudioLength.seconds(ofStream: URL(string: "https://x.googlevideo.com/videoplayback?dur=0")!))
    }

    func testCleanTitleStripsVideoDecorations() {
        XCTAssertEqual(Lyrics.cleanTitle("Hello (Official Music Video)", artist: "Adele"), "Hello")
        XCTAssertEqual(Lyrics.cleanTitle("Adele - Hello (Official Music Video)", artist: "Adele"), "Hello")
        XCTAssertEqual(Lyrics.cleanTitle("Darmiyaan (Full Video) | Musafir Cafe | Vikrant Massey", artist: "Rekha Bhardwaj"), "Darmiyaan")
        XCTAssertEqual(Lyrics.cleanTitle("Song [Lyric Video]", artist: ""), "Song")
        XCTAssertEqual(Lyrics.cleanTitle("Song (Remastered 2011)", artist: ""), "Song")
    }

    func testCleanTitleKeepsRealTitles() {
        XCTAssertEqual(Lyrics.cleanTitle("Uptown Funk (feat. Bruno Mars)", artist: "Mark Ronson"), "Uptown Funk (feat. Bruno Mars)")
        XCTAssertEqual(Lyrics.cleanTitle("Darmiyaan", artist: "Rekha Bhardwaj"), "Darmiyaan")
        XCTAssertEqual(Lyrics.cleanTitle("Video Killed the Radio Star", artist: "The Buggles"), "Video Killed the Radio Star")
        XCTAssertEqual(Lyrics.cleanTitle("(Official Video)", artist: ""), "(Official Video)", "never returns an empty title")
    }
}
