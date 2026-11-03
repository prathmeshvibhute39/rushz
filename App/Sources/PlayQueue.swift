import Foundation

/// The listening session as a plain value: what played, what plays now, and the explicit queue behind it.
/// When `upcoming` is empty the player asks YouTube's autoplay what comes next (or wraps around on repeat-all).
struct PlayQueue: Equatable {
    private(set) var played: [Track] = []
    private(set) var current: Track?
    private(set) var upcoming: [Track] = []

    init(current: Track? = nil, upcoming: [Track] = []) {
        self.current = current
        self.upcoming = upcoming
    }

    var canGoBack: Bool { !played.isEmpty }

    /// A fresh session: `t` now, then `queue` in order.
    mutating func start(_ t: Track, then queue: [Track]) {
        self = PlayQueue(current: t, upcoming: queue)
    }

    /// The player reports that `t` is now playing (it advanced by itself, or we started it).
    mutating func didStart(_ t: Track) {
        guard let cur = current else { current = t; return }
        guard cur.id != t.id else { return }
        if upcoming.first?.id == t.id {
            upcoming.removeFirst()
            played.append(cur)
        } else if upcoming.isEmpty, played.first?.id == t.id {
            // repeat-all wrapped around to the start of the session: the rest of it is queued again
            upcoming = Array(played.dropFirst()) + [cur]
            played = []
        } else {
            played.append(cur)  // e.g. YouTube's autoplay pick
        }
        current = t
    }

    /// Steps back. The track we leave goes to the front of `upcoming`, so "next" returns to where you were.
    mutating func goBack() -> Track? {
        guard let previous = played.popLast() else { return nil }
        if let cur = current { upcoming.insert(cur, at: 0) }
        current = previous
        return previous
    }

    /// Jumps to `upcoming[index]`; the skipped tracks count as played.
    mutating func skip(to index: Int) -> Track? {
        guard upcoming.indices.contains(index) else { return nil }
        if let cur = current { played.append(cur) }
        played.append(contentsOf: upcoming[..<index])
        current = upcoming[index]
        upcoming.removeFirst(index + 1)
        return current
    }

    mutating func playNext(_ t: Track) { upcoming.insert(t, at: 0) }
    mutating func append(_ t: Track) { upcoming.append(t) }
    mutating func remove(at offsets: IndexSet) { upcoming.remove(atOffsets: offsets) }
    mutating func move(from offsets: IndexSet, to destination: Int) { upcoming.move(fromOffsets: offsets, toOffset: destination) }

    mutating func shuffleUpcoming<G: RandomNumberGenerator>(using g: inout G) { upcoming.shuffle(using: &g) }
    mutating func shuffleUpcoming() {
        var g = SystemRandomNumberGenerator()
        shuffleUpcoming(using: &g)
    }

    /// What follows without asking YouTube: the explicit queue, or (repeat-all) the start of the session.
    func next(repeatAll: Bool) -> Track? {
        upcoming.first ?? (repeatAll ? played.first : nil)
    }
}
