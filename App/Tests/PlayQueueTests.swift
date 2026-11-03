import XCTest
@testable import Rushz

final class PlayQueueTests: XCTestCase {
    private func t(_ n: Int) -> Track { Track(id: String(format: "track%06d", n), title: "T\(n)", channel: "A", duration: "1:00") }
    private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.title) }

    func testStartSetsCurrentAndQueue() {
        var q = PlayQueue()
        q.start(t(1), then: [t(2), t(3)])
        XCTAssertEqual(q.current?.title, "T1")
        XCTAssertEqual(ids(q.upcoming), ["T2", "T3"])
        XCTAssertFalse(q.canGoBack)
    }

    func testDidStartAdvancesThroughQueue() {
        var q = PlayQueue(current: t(1), upcoming: [t(2), t(3)])
        q.didStart(t(2))
        XCTAssertEqual(q.current?.title, "T2")
        XCTAssertEqual(ids(q.played), ["T1"])
        XCTAssertEqual(ids(q.upcoming), ["T3"])
    }

    func testDidStartSameTrackChangesNothing() {
        var q = PlayQueue(current: t(1), upcoming: [t(2)])
        q.didStart(t(1))
        XCTAssertEqual(q, PlayQueue(current: t(1), upcoming: [t(2)]))
    }

    func testAutoplayPickIsRecordedAsPlayed() {
        var q = PlayQueue(current: t(1))
        q.didStart(t(9))  // not in the queue: YouTube's autoplay pick
        XCTAssertEqual(q.current?.title, "T9")
        XCTAssertEqual(ids(q.played), ["T1"])
    }

    func testGoBackPutsCurrentBackInFrontOfQueue() {
        var q = PlayQueue(current: t(1), upcoming: [t(2), t(3)])
        q.didStart(t(2))
        let back = q.goBack()
        XCTAssertEqual(back?.title, "T1")
        XCTAssertEqual(q.current?.title, "T1")
        XCTAssertEqual(ids(q.upcoming), ["T2", "T3"])  // "next" returns to where you were
        XCTAssertFalse(q.canGoBack)
    }

    func testGoBackWithNothingPlayedReturnsNil() {
        var q = PlayQueue(current: t(1))
        XCTAssertNil(q.goBack())
        XCTAssertEqual(q.current?.title, "T1")
    }

    func testSkipToMarksSkippedTracksPlayed() {
        var q = PlayQueue(current: t(1), upcoming: [t(2), t(3), t(4)])
        XCTAssertEqual(q.skip(to: 1)?.title, "T3")
        XCTAssertEqual(q.current?.title, "T3")
        XCTAssertEqual(ids(q.played), ["T1", "T2"])
        XCTAssertEqual(ids(q.upcoming), ["T4"])
    }

    func testSkipOutOfRangeIsIgnored() {
        var q = PlayQueue(current: t(1), upcoming: [t(2)])
        XCTAssertNil(q.skip(to: 5))
        XCTAssertEqual(q, PlayQueue(current: t(1), upcoming: [t(2)]))
    }

    func testQueueEditing() {
        var q = PlayQueue(current: t(1), upcoming: [t(2), t(3)])
        q.playNext(t(7))
        q.append(t(8))
        XCTAssertEqual(ids(q.upcoming), ["T7", "T2", "T3", "T8"])
        q.move(from: IndexSet(integer: 3), to: 0)
        XCTAssertEqual(ids(q.upcoming), ["T8", "T7", "T2", "T3"])
        q.remove(at: IndexSet(integersIn: 0..<2))
        XCTAssertEqual(ids(q.upcoming), ["T2", "T3"])
    }

    func testShuffleKeepsTheSameTracksAndIsDeterministicWithASeed() {
        struct Seeded: RandomNumberGenerator {  // SplitMix64
            var s: UInt64
            mutating func next() -> UInt64 {
                s &+= 0x9E3779B97F4A7C15
                var z = s
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
        }
        let tracks = (2...9).map(t)
        var a = PlayQueue(current: t(1), upcoming: tracks), b = a
        var g1 = Seeded(s: 42), g2 = Seeded(s: 42)
        a.shuffleUpcoming(using: &g1)
        b.shuffleUpcoming(using: &g2)
        XCTAssertEqual(a.upcoming, b.upcoming)
        XCTAssertEqual(Set(a.upcoming.map(\.id)), Set(tracks.map(\.id)))
        XCTAssertEqual(a.current?.title, "T1")
    }

    func testNextPrefersQueueThenRepeatAll() {
        var q = PlayQueue(current: t(1), upcoming: [t(2)])
        XCTAssertEqual(q.next(repeatAll: false)?.title, "T2")
        q.didStart(t(2))
        XCTAssertNil(q.next(repeatAll: false))               // queue used up: YouTube autoplay decides
        XCTAssertEqual(q.next(repeatAll: true)?.title, "T1") // repeat-all wraps to the session start
    }

    func testRepeatAllCyclesThroughTheWholeSession() {
        var q = PlayQueue(current: t(1), upcoming: [t(2), t(3)])
        q.didStart(t(2)); q.didStart(t(3))
        XCTAssertEqual(q.next(repeatAll: true)?.title, "T1")
        q.didStart(t(1))  // wrapped around: the rest of the session is queued again, in order
        XCTAssertEqual(q.current?.title, "T1")
        XCTAssertEqual(ids(q.upcoming), ["T2", "T3"])
        XCTAssertTrue(q.played.isEmpty)
        q.didStart(t(2)); q.didStart(t(3))
        XCTAssertEqual(q.next(repeatAll: true)?.title, "T1")  // and it keeps cycling
    }

    func testRepeatAllOnASingleTrackFallsBackToAutoplay() {
        let q = PlayQueue(current: t(1))
        XCTAssertNil(q.next(repeatAll: true))  // single tracks use repeat-one
    }
}
