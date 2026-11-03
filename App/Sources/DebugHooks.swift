#if DEBUG
import Foundation

/// Debug-only launch hooks so behaviour can be checked from the command line (never compiled into release builds).
/// Set them with `SIMCTL_CHILD_<NAME>=value xcrun simctl launch …`.
extension Player {
    func runDebugHooks() {
        let env = ProcessInfo.processInfo.environment

        // RUSHZ_TEST_ID=videoId : play one song
        if let id = env["RUSHZ_TEST_ID"] {
            Task { start(await Search.details(id: id) ?? Track(id: id, title: "Test \(id)", channel: "debug", duration: "")) }
        }

        // RUSHZ_TEST_SEARCH=query : log parsed results and the autoplay pick for the first one
        if let q = env["RUSHZ_TEST_SEARCH"] {
            Task {
                let r = (try? await Search.run(q)) ?? []
                log.info("search '\(q, privacy: .public)': \(r.count) songs")
                for t in r.prefix(4) { log.info("  \(t.id, privacy: .public) | \(t.title, privacy: .public) | \(t.channel, privacy: .public) | \(t.duration, privacy: .public) | square=\(t.isSquareArt)") }
                if let first = r.first, let n = try? await Search.upNext(after: first.id) {
                    log.info("upNext after \(first.id, privacy: .public): \(n.id, privacy: .public) | \(n.title, privacy: .public)")
                } else { log.info("upNext: none") }
            }
        }

        // RUSHZ_TEST_QUEUE=a,b,c : play a with b,c queued, then skip twice
        if let ids = env["RUSHZ_TEST_QUEUE"]?.split(separator: ",").map(String.init) {
            Task {
                var list: [Track] = []
                for id in ids { list.append(await Search.details(id: id) ?? Track(id: id, title: "Test \(id)", channel: "debug", duration: "")) }
                start(list[0], then: Array(list.dropFirst()))
                try? await Task.sleep(for: .seconds(20)); next()
                try? await Task.sleep(for: .seconds(15)); next()
            }
        }

        // RUSHZ_TEST_ENDGAME=off|one|all (with RUSHZ_TEST_ID): jump to 4 s before the end and log what happens next
        if let mode = env["RUSHZ_TEST_ENDGAME"], let id = env["RUSHZ_TEST_ID"] {
            Task {
                try? await Task.sleep(for: .seconds(14))
                repeatMode = RepeatMode(rawValue: mode) ?? .off
                log.info("endgame: repeat=\(mode, privacy: .public) length=\(self.duration) now=\(self.time) track=\(id, privacy: .public)")
                seek(to: max(0, duration - 4))
                for _ in 0..<4 {
                    try? await Task.sleep(for: .seconds(4))
                    log.info("endgame: t=\(self.time, format: .fixed(precision: 1)) track=\(self.current?.id ?? "-", privacy: .public) playing=\(self.isPlaying)")
                }
            }
        }

        // RUSHZ_TEST_SLEEP=minutes|end (with RUSHZ_TEST_ID): arm the sleep timer, then log whether playback stops
        if let mode = env["RUSHZ_TEST_SLEEP"] {
            Task {
                try? await Task.sleep(for: .seconds(10))
                if mode == "end" {
                    setSleep(.endOfTrack)
                    seek(to: max(0, duration - 4))
                } else { setSleep(.minutes(Int(mode) ?? 1)) }
                log.info("sleep: armed \(mode, privacy: .public) at t=\(self.time, format: .fixed(precision: 1))")
                for _ in 0..<(mode == "end" ? 3 : 9) {
                    try? await Task.sleep(for: .seconds(mode == "end" ? 4 : 10))
                    log.info("sleep: t=\(self.time, format: .fixed(precision: 1)) track=\(self.current?.id ?? "-", privacy: .public) playing=\(self.isPlaying) timer=\(String(describing: self.sleep), privacy: .public)")
                }
            }
        }

        // RUSHZ_TEST_LYRICS=artist|title|seconds : log what the lyrics lookup finds
        if let spec = env["RUSHZ_TEST_LYRICS"]?.split(separator: "|").map(String.init), spec.count == 3 {
            Task {
                let t = Track(id: String(format: "lyric%06d", abs(spec[1].hashValue) % 1_000_000), title: spec[1], channel: spec[0], duration: "")  // unique id per title, so the cache can't mix songs up
                let l = await Lyrics.fetch(for: t, duration: Double(spec[2]) ?? 0)
                log.info("lyrics: \(l.map { "\($0.lines.count) lines, synced=\($0.isSynced)" } ?? "none", privacy: .public)")
                if let first = l?.lines.first { log.info("  first line: \(first.text, privacy: .public) @ \(first.time ?? -1)") }
            }
        }

        // RUSHZ_TEST_FEED=1 : log the account feed and liked songs
        if env["RUSHZ_TEST_FEED"] != nil {
            Task {
                await Account.shared.refresh()
                await Feed.shared.refresh()
                log.info("feed: signedIn=\(Account.shared.isSignedIn) shelves=\(Feed.shared.shelves.count) liked=\(Feed.shared.liked.count)")
                if let j = try? await Search.browse("VLLM") {
                    let text = String(data: (try? JSONSerialization.data(withJSONObject: j)) ?? Data(), encoding: .utf8) ?? ""
                    let rows = text.components(separatedBy: "musicResponsiveListItemRenderer").count - 1
                    log.info("liked page: \(text.count) chars, rows=\(rows), playlistShelf=\(text.contains("musicPlaylistShelfRenderer")), top=\((j as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "-", privacy: .public)")
                    if let r = text.range(of: "\"subtitle\":{\"runs\":[{\"text\":\"") { log.info("  subtitle: \(String(text[r.upperBound...].prefix(60)), privacy: .public)") }
                } else { log.info("liked page: request failed") }
                                for s in Feed.shared.shelves.prefix(4) { log.info("  shelf '\(s.title, privacy: .public)': \(s.tracks.count) tracks, first: \(s.tracks.first?.title ?? "-", privacy: .public)") }
            }
        }
    }
}
#endif
