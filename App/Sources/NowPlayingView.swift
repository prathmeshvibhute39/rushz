import AVKit
import SwiftUI

// MARK: - shared bits

/// Critically damped by default (no bounce); the dismiss gesture uses a little bounce because it carries momentum.
enum Motion {
    static let smooth = Animation.spring(response: 0.4, dampingFraction: 1.0)
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 1.0)
    static let sheet = Animation.spring(response: 0.3, dampingFraction: 0.8)
}

struct Cover: View {
    let track: Track
    var body: some View {
        // Color.clear takes whatever size the parent proposes, so the image can never widen the layout
        Color.clear
            .overlay {
                AsyncImage(url: track.thumbnail) { img in
                    // hqdefault is a 16:9 picture letterboxed into 4:3; the zoom crops the bars off
                    img.resizable().scaledToFill().scaleEffect(track.isSquareArt ? 1 : 1.34)
                } placeholder: {
                    Rectangle().fill(.white.opacity(0.08))
                }
            }
            .clipped()
    }
}

/// Feedback on touch-down, not release: the control reacts the instant it is pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()  // fires with the action, same frame as the visual
}

func clock(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
}

/// A thin bar that thickens under the finger and tracks it 1:1, relative to where the touch began.
struct Scrubber: View {
    let progress: Double
    let onSeek: (Double) -> Void
    @State private var start: Double?
    @State private var live: Double?

    var body: some View {
        GeometryReader { g in
            let shown = live ?? progress
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white).frame(width: max(0, g.size.width * shown))
            }
            .frame(height: live == nil ? 6 : 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(Motion.snappy, value: live == nil)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if start == nil { start = progress; UISelectionFeedbackGenerator().selectionChanged() }
                        live = min(1, max(0, (start ?? 0) + v.translation.width / g.size.width))
                    }
                    .onEnded { _ in
                        if let live { onSeek(live) }
                        start = nil
                        live = nil
                    }
            )
        }
        .frame(height: 32)
    }
}

// MARK: - full player

/// One 24 pt margin for everything, an 8 pt rhythm, the cover as the hero, controls anchored to the bottom.
struct NowPlayingView: View {
    @EnvironmentObject var player: Player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let close: () -> Void
    /// 0 (resting) … 1 (dragged away): lets the page behind un-dim and grow back in step with your finger.
    @Binding var dismissProgress: CGFloat
    @State private var drag: CGFloat = 0
    @State private var showQueue = false
    @State private var showLyrics = false
    private let margin: CGFloat = 24
    /// The device's real safe-area insets (notch / home indicator); the container reports extra bottom inset from the search bar.
    private var insets: UIEdgeInsets {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets ?? .zero
    }

    var body: some View {
        if let t = player.current {
            GeometryReader { g in
                ZStack {
                    backdrop(t)
                    VStack(spacing: 0) {
                        Capsule().fill(.white.opacity(0.35)).frame(width: 36, height: 5).padding(.top, 8)
                        artwork(t, side: min(g.size.width - margin * 2, (g.size.height - insets.top - insets.bottom) * 0.46)).padding(.top, 16)
                        titleRow(t).padding(.top, 24)
                        Spacer(minLength: 12)  // the two flexible gaps share whatever height is left
                        progress
                        transport.padding(.top, 8)
                        Spacer(minLength: 12)
                        extras.frame(height: 44)  // pinned: the UIKit AirPlay picker would otherwise stretch this row
                    }
                    .padding(.horizontal, margin)
                    .padding(.top, insets.top)
                    .padding(.bottom, insets.bottom + 12)
                    .contentShape(Rectangle())
                    .gesture(dismissDrag)  // controls keep their own gestures; everywhere else drags the sheet
                }
                .frame(width: g.size.width, height: g.size.height)  // use the whole screen: controls anchor to the bottom
            }
            .ignoresSafeArea()
            .background(Color.black)  // before .offset, so the base moves with the player instead of hiding the page behind
            .clipShape(RoundedRectangle(cornerRadius: min(38, max(0, drag) * 0.5), style: .continuous))  // a card while dragged
            .offset(y: offset)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showQueue) { QueueView().environmentObject(player) }
            .sheet(isPresented: $showLyrics) { LyricsView().environmentObject(player) }
            #if DEBUG
            .onAppear {
                switch ProcessInfo.processInfo.environment["RUSHZ_OPEN"] {
                case "queue": showQueue = true
                case "lyrics": showLyrics = true
                default: break
                }
            }
            #endif
        }
    }

    // MARK: pieces

    /// Blurred, darkened cover colour behind everything.
    private func backdrop(_ t: Track) -> some View {
        Cover(track: t)
            .blur(radius: 80)
            .overlay(LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            .drawingGroup()  // rasterise the blur once; moving the sheet then costs nothing
            .ignoresSafeArea()
    }

    private func artwork(_ t: Track, side: CGFloat) -> some View {
        Cover(track: t)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 28, y: 14)
            .scaleEffect(player.isPlaying ? 1 : 0.88)  // rests a little smaller while paused
            .animation(reduceMotion ? .none : Motion.smooth, value: player.isPlaying)
    }

    /// Title and artist left-aligned on the margin, the add-to-playlist action right-aligned on the same row.
    private func titleRow(_ t: Track) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.title)
                    .font(.system(size: 22, weight: .bold)).tracking(-0.3)
                    .lineLimit(2)
                Text(player.status ?? t.channel)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { tap(); Playlists.shared.pendingAdd = t } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Add to playlist")
        }
    }

    private var progress: some View {
        VStack(spacing: 2) {
            Scrubber(progress: player.duration > 0 ? player.time / player.duration : 0) {
                player.seek(to: $0 * player.duration)
            }
            HStack {
                Text(clock(player.time))
                Spacer()
                Text(player.duration > 0 ? "-" + clock(max(0, player.duration - player.time)) : "–:––")
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// Previous / play-pause / next: play is the biggest target, skips are equal and symmetric around it.
    private var transport: some View {
        HStack(spacing: 40) {
            Button { tap(); player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 34)).frame(width: 64, height: 64)
            }
            .accessibilityLabel("Previous")
            Button { tap(.medium); player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 56)).frame(width: 80, height: 80)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { tap(); player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 34)).frame(width: 64, height: 64)
            }
            .accessibilityLabel("Next")
        }
        .buttonStyle(PressStyle())
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    /// Shuffle, repeat, lyrics, sleep timer, queue, AirPlay: six equal 44 pt targets, one icon size and weight.
    private var extras: some View {
        HStack(spacing: 0) {
            extra("shuffle", on: player.shuffleOn, label: "Shuffle") { player.shuffleOn.toggle() }
            extra(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off, label: "Repeat") {
                player.repeatMode = player.repeatMode == .off ? .all : player.repeatMode == .all ? .one : .off
            }
            extra("quote.bubble", label: "Lyrics") { showLyrics = true }
            Menu {
                Button("Off") { player.setSleep(.off) }
                ForEach([15, 30, 45, 60], id: \.self) { m in Button("\(m) minutes") { player.setSleep(.minutes(m)) } }
                Button("End of this song") { player.setSleep(.endOfTrack) }
            } label: {
                glyph("moon.zzz", on: player.sleep != .off)
            }
            .accessibilityLabel("Sleep timer")
            extra("list.bullet", label: "Queue") { showQueue = true }
            ZStack {
                glyph("airplayaudio", on: false)
                AirPlayPicker()  // invisible system picker on top of our own icon, so the size matches the others
            }
            .accessibilityLabel("AirPlay")
        }
    }

    private func glyph(_ icon: String, on: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(on ? Color.accentColor : .white.opacity(0.62))
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func extra(_ icon: String, on: Bool = false, label: String, action: @escaping () -> Void) -> some View {
        Button { tap(); action() } label: { glyph(icon, on: on) }
            .buttonStyle(PressStyle())
            .accessibilityLabel(label)
    }

    // MARK: dismiss

    /// Follows the finger 1:1 downward, resists upward, then decides by where the throw would land.
    private var offset: CGFloat { drag >= 0 ? drag : -(sqrt(-drag) * 3) }

    /// Measured in the screen's own coordinates: the sheet moves with the finger, so a gesture measured in the
    /// sheet's coordinates would feed its own movement back into itself and flicker.
    private var dismissDrag: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged {
                drag = $0.translation.height
                dismissProgress = min(1, max(0, drag / 420))
            }
            .onEnded { v in
                if v.predictedEndTranslation.height > 260 {
                    guard !reduceMotion else { return close() }
                    // carry on off the bottom of the screen from exactly where the finger let go, then remove
                    withAnimation(Motion.smooth, completionCriteria: .removed) {
                        drag = insets.top + 1000
                        dismissProgress = 1
                    } completion: { close() }
                } else {
                    withAnimation(reduceMotion ? .none : Motion.sheet) {
                        drag = 0
                        dismissProgress = 0
                    }
                }
            }
    }
}

/// The system AirPlay / output picker, drawn invisibly so our own icon is what you see.
struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .clear
        v.activeTintColor = .clear
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}
