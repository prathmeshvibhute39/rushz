import AVFoundation
import Combine
import MediaPlayer
import UIKit
import YouTubeKit
import os

/// Resolves + caches stream URLs. YouTubeKit downloads and runs YouTube's player script on every
/// resolve (seconds), so results are cached and in-flight requests are shared.
actor StreamResolver {
    private var cache: [String: (url: URL, expires: Date)] = [:]
    private var inflight: [String: Task<URL, Error>] = [:]

    func url(for id: String) async throws -> URL {
        if let hit = cache[id], hit.expires > .now { return hit.url }
        if let running = inflight[id] { return try await running.value }
        let task = Task<URL, Error> {
            // local only: never send IDs to a third-party extraction server
            let stream = try await YouTube(videoID: id, methods: [.local]).streams
                .filterAudioOnly()
                .filter { $0.isNativelyPlayable && $0.url.scheme == "https" }
                .highestAudioBitrateStream()
            guard let stream else { throw URLError(.resourceUnavailable) }
            // videos with a preroll ad: YouTube only serves the stream after a few seconds (403 before that)
            try await stream.waitUntilAvailable()
            Logger(subsystem: "com.example.rushz", category: "stream").info("picked \(stream.mimeType, privacy: .public) avg \(stream.averageBitrate ?? 0) bps")
            return stream.url
        }
        inflight[id] = task
        defer { inflight[id] = nil }
        let url = try await task.value
        cache[id] = (url, .now.addingTimeInterval(4 * 3600))  // stream URLs live ~6h
        return url
    }
}

enum RepeatMode: String, CaseIterable { case off, all, one }
enum SleepTimer: Equatable { case off, minutes(Int), endOfTrack }

/// Audio-only player on an AVQueuePlayer. While a track plays, whatever comes next (your queue, or YouTube's
/// autoplay pick) is resolved and queued behind it, so track changes are instant, gapless, and work with the screen off.
@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue = PlayQueue()
    @Published private(set) var isPlaying = false
    @Published private(set) var status: String?
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var sleep: SleepTimer = .off
    @Published private(set) var sleepEndsAt: Date?
    @Published var shuffleOn = false {
        didSet { if shuffleOn && !oldValue { queue.shuffleUpcoming(); queueEdited() } }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { if repeatMode != oldValue { queueEdited() } }
    }

    var current: Track? { queue.current }
    var hasPrevious: Bool { queue.canGoBack || time > 3 }

    private let player = AVQueuePlayer()
    private let resolver = StreamResolver()
    private let library = Library.shared
    private var trackOf: [ObjectIdentifier: Track] = [:]
    private var realLength: [ObjectIdentifier: Double] = [:]  // AVPlayer double-counts YouTube m4a, see AudioLength
    private var ended = Set<ObjectIdentifier>()  // items whose end we already handled
    private var failures = 0  // consecutive unplayable tracks; stops the auto-skip from looping forever
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var artwork: [String: MPMediaItemArtwork] = [:]
    private var bag = Set<AnyCancellable>()
    private var itemBag = Set<AnyCancellable>()
    let log = Logger(subsystem: "com.example.rushz", category: "player")

    init() {
        player.automaticallyWaitsToMinimizeStalling = false  // audio is tiny; start as soon as bytes arrive
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)

        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        player.publisher(for: \.timeControlStatus)
            .map { $0 != .paused }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.isPlaying = $0; self?.updateNowPlaying() }
            .store(in: &bag)
        player.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.itemChanged($0) }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in
                if let item = n.object as? AVPlayerItem { self?.trackEnded(item, reachedPlayersEnd: true) }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in
                let raw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                if AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) { self?.player.play() }
            }
            .store(in: &bag)

        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { [weak self] _ in self?.set(playing: true); return .success }
        rc.pauseCommand.addTarget { [weak self] _ in self?.set(playing: false); return .success }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        rc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        rc.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        rc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
        #if DEBUG
        runDebugHooks()
        #endif
    }

    // MARK: - controls

    /// Starts a fresh listening session from a chosen track. `then` is played in order before autoplay takes over.
    func start(_ t: Track, then rest: [Track] = []) {
        queue.start(t, then: rest)
        if shuffleOn { queue.shuffleUpcoming() }
        load(t)
    }

    func toggle() { set(playing: !isPlaying) }

    private func set(playing: Bool) {
        isPlaying = playing  // optimistic: the UI never waits on the audio engine
        playing ? player.play() : player.pause()
    }

    func next() {
        if player.items().count > 1 { return player.advanceToNextItem() }  // prefetched: instant
        guard let t = current else { return }
        status = "Finding next…"
        loadTask?.cancel()
        loadTask = Task {
            guard let n = await nextTrack(after: t), !Task.isCancelled else {
                status = "No autoplay available"
                return
            }
            load(n)
        }
    }

    func previous() {
        if time > 3 || !queue.canGoBack { return seek(to: 0) }
        if let p = queue.goBack() { load(p) }  // URL is cached, so this is instant too
    }

    func seek(to seconds: Double) {
        time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - queue editing (all of these re-do the prefetch, since what comes next may have changed)

    func jump(toUpcoming index: Int) {
        if let t = queue.skip(to: index) { load(t) }
    }

    func playNext(_ t: Track) { queue.playNext(t); queueEdited() }
    func addToQueue(_ t: Track) { queue.append(t); queueEdited() }
    func removeUpcoming(at offsets: IndexSet) { queue.remove(at: offsets); queueEdited() }
    func moveUpcoming(from offsets: IndexSet, to destination: Int) { queue.move(from: offsets, to: destination); queueEdited() }

    private func queueEdited() {
        for it in player.items().dropFirst() { player.remove(it) }
        if let t = current { prefetchNext(after: t) }
    }

    // MARK: - sleep timer

    func setSleep(_ s: SleepTimer) {
        sleepTask?.cancel()
        player.actionAtItemEnd = .advance
        player.volume = 1
        sleep = s
        sleepEndsAt = nil
        switch s {
        case .off: break
        case .endOfTrack: player.actionAtItemEnd = .pause
        case .minutes(let m):
            let end = Date.now.addingTimeInterval(Double(m) * 60)
            sleepEndsAt = end
            sleepTask = Task {
                try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
                guard !Task.isCancelled else { return }
                for step in stride(from: 19, through: 0, by: -1) {  // 3-second fade-out
                    player.volume = Float(step) / 20
                    try? await Task.sleep(for: .milliseconds(150))
                }
                player.pause()
                player.volume = 1
                sleep = .off
                sleepEndsAt = nil
            }
        }
    }

    // MARK: - loading

    /// What plays after `t`: your queue, then YouTube's autoplay pick, then your library when offline.
    private func nextTrack(after t: Track) async -> Track? {
        if let n = queue.next(repeatAll: repeatMode == .all) { return n }
        return (try? await Search.upNext(after: t.id)) ?? library.following(t)
    }

    /// A saved copy if there is one (instant, works offline), otherwise the network stream.
    private func source(for id: String) async throws -> URL {
        if let local = library.localURL(id) {
            library.touch(id)
            return local
        }
        return try await resolver.url(for: id)
    }

    private func saveCopy(_ t: Track) {
        guard library.autoSave, library.localURL(t.id) == nil else { return }
        Task { if let url = try? await resolver.url(for: t.id) { await library.save(t, from: url) } }
    }

    private func load(_ t: Track) {
        loadTask?.cancel()
        prefetchTask?.cancel()
        queue.didStart(t)
        status = "Loading…"
        time = 0
        duration = 0
        loadTask = Task {
            do {
                let url = try await source(for: t.id)
                guard !Task.isCancelled else { return }
                player.removeAllItems()
                player.insert(item(url, t), after: nil)
                player.play()
                status = nil
            } catch {
                guard !Task.isCancelled else { return }
                log.error("resolve failed \(t.id, privacy: .public): \(String(describing: error), privacy: .public)")
                if let e = error as? YouTubeKitError, e == .loginRequired {
                    // nothing to skip to: every track hits the same gate until you (re)sign in
                    status = Account.shared.isSignedIn ? "Session expired — sign in again" : "Sign in to play"
                    Account.shared.needsAttention = true
                    return
                }
                status = Self.message(for: error)
                failures += 1
                guard failures <= 3 else { return }  // after 3 in a row, stop and let you choose
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled, current?.id == t.id { next() }
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let e = error as? YouTubeKitError, let d = e.errorDescription { return "\(d) — skipping" }
        return "YouTube wouldn't serve this track — skipping"
    }

    private func item(_ url: URL, _ t: Track) -> AVPlayerItem {
        let it = AVPlayerItem(url: url)
        trackOf[ObjectIdentifier(it)] = t
        let known = url.isFileURL ? AudioLength.seconds(ofFile: url) : AudioLength.seconds(ofStream: url)
        if let len = known ?? AudioLength.seconds(ofClock: t.duration) { realLength[ObjectIdentifier(it)] = len }
        return it
    }

    /// Resolve what follows `t` and queue it behind the current item.
    private func prefetchNext(after t: Track) {
        prefetchTask?.cancel()
        guard repeatMode != .one, player.items().count < 2 else { return }  // repeat-one replays the same track
        prefetchTask = Task {
            guard let n = await nextTrack(after: t),
                  let url = try? await source(for: n.id),
                  !Task.isCancelled, player.items().count < 2,
                  player.items().last.flatMap({ trackOf[ObjectIdentifier($0)] })?.id == t.id else { return }
            player.insert(item(url, n), after: player.items().last)
        }
    }

    /// `reachedPlayersEnd`: AVPlayer itself got to the end (and moves on by itself if something is queued).
    /// Otherwise we noticed the real end of a song that AVPlayer thinks is twice as long, so we move on ourselves.
    private func trackEnded(_ item: AVPlayerItem, reachedPlayersEnd: Bool) {
        guard item === player.currentItem, ended.insert(ObjectIdentifier(item)).inserted else { return }
        if sleep == .endOfTrack {  // stay quiet, but ready the next track
            setSleep(.off)
            player.pause()
            player.advanceToNextItem()
            return
        }
        if repeatMode == .one, let t = current { return load(t) }
        if reachedPlayersEnd {
            if player.items().count <= 1 { next() }  // fallback only: normally the queued item takes over by itself
        } else if player.items().count > 1 {
            player.advanceToNextItem()  // the prefetched next track: instant
        } else {
            next()
        }
    }

    private func itemChanged(_ item: AVPlayerItem?) {
        let live = Set(player.items().map(ObjectIdentifier.init))
        trackOf = trackOf.filter { live.contains($0.key) }
        realLength = realLength.filter { live.contains($0.key) }
        ended = ended.filter { live.contains($0) }
        itemBag.removeAll()
        guard let item, let t = trackOf[ObjectIdentifier(item)] else { return }
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] st in
                guard st == .failed else { return }
                let e = item.error as NSError?
                self?.log.error("playback failed \(t.id, privacy: .public): \(e?.domain ?? "?", privacy: .public) \(e?.code ?? 0) \(e?.localizedDescription ?? "", privacy: .public)")
                self?.status = "Can't play this track"
            }
            .store(in: &itemBag)
        queue.didStart(t)
        failures = 0
        time = 0
        duration = 0
        status = nil
        History.shared.record(t)
        log.info("now playing \(t.id, privacy: .public) (queued: \(self.queue.upcoming.map(\.id).joined(separator: ","), privacy: .public))")
        loadArtwork(for: t)
        saveCopy(t)
        prefetchNext(after: t)
    }

    // MARK: - now playing

    private func tick(_ t: Double) {
        time = t.isFinite ? t : 0
        guard let item = player.currentItem else { return }
        var d = item.duration.seconds
        if let real = realLength[ObjectIdentifier(item)], !d.isFinite || d > real * 1.4 { d = real }  // AVPlayer reports ~2x
        // AVPlayer would keep "playing" (silence) for as long again as the song: end it at the real length ourselves
        if let real = realLength[ObjectIdentifier(item)], time >= real - 0.05 { trackEnded(item, reachedPlayersEnd: false) }
        if d.isFinite, d > 0, d != duration {
            log.info("length \(d, format: .fixed(precision: 1)) s for \(self.current?.id ?? "-", privacy: .public)")
            duration = d
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard let t = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.channel,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let art = artwork[t.id] { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Lock-screen cover: fetched once per track, square-cropped (video frames lose their letterbox bars).
    private func loadArtwork(for t: Track) {
        guard artwork[t.id] == nil, let url = t.thumbnail else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            let square = Self.centerSquare(image, cropVideoBars: !t.isSquareArt)
            artwork[t.id] = MPMediaItemArtwork(boundsSize: square.size) { _ in square }
            if current?.id == t.id { updateNowPlaying() }
        }
    }

    /// hqdefault is a 16:9 picture letterboxed into 4:3, so the visible part is 75% of the height.
    nonisolated static func centerSquare(_ image: UIImage, cropVideoBars: Bool) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let side = CGFloat(min(cg.width, cg.height)) * (cropVideoBars ? 0.75 : 1)
        let rect = CGRect(x: (CGFloat(cg.width) - side) / 2, y: (CGFloat(cg.height) - side) / 2, width: side, height: side)
        return cg.cropping(to: rect).map { UIImage(cgImage: $0, scale: image.scale, orientation: image.imageOrientation) } ?? image
    }
}
