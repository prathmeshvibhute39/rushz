import AudioToolbox
import Foundation

/// The real length of a song. AVPlayer reports twice the real length for YouTube's fragmented m4a files,
/// so the player trusts these sources instead: the file itself (CoreAudio parses it correctly) or the stream URL's `dur`.
enum AudioLength {
    /// Duration of a local audio file, read by CoreAudio.
    static func seconds(ofFile url: URL) -> Double? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let f = file else { return nil }
        defer { AudioFileClose(f) }
        var seconds: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioFileGetProperty(f, kAudioFilePropertyEstimatedDuration, &size, &seconds) == noErr, seconds > 0 else { return nil }
        return seconds
    }

    /// Duration YouTube states in a stream URL (`…&dur=366.841&…`).
    static func seconds(ofStream url: URL) -> Double? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dur" }?.value.flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
    }

    /// "4:31" → 271 (what a Track carries when nothing better is known).
    static func seconds(ofClock s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == s.split(separator: ":").count else { return nil }
        let v = parts.reduce(0) { $0 * 60 + $1 }
        return v > 0 ? v : nil
    }
}
