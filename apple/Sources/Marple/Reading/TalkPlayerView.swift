import SwiftUI
import AVKit
import MarpleKit

/// Owns the `AVPlayer` for the talk/transcript player: loads media, seeks, and
/// (when a `recording.srt` sidecar exists) tracks the synced caption. Kept as a
/// reference type so the periodic time observer always reads the current cues.
@MainActor
final class TalkPlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var caption: String = ""

    private var cues: [SRTCue] = []
    private var loadedMedia: URL?
    private var observer: Any?

    /// Load the media if it changed, then seek to the requested time and play.
    func apply(_ pb: AppModel.TalkPlayback) {
        if loadedMedia != pb.mediaURL {
            player.replaceCurrentItem(with: AVPlayerItem(url: pb.mediaURL))
            loadedMedia = pb.mediaURL
            cues = pb.subtitlesURL
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                .map(SRT.parse) ?? []
            caption = ""
            installObserver()
        }
        player.seek(to: CMTime(seconds: pb.seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func teardown() {
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.pause()
    }

    private func installObserver() {
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        guard !cues.isEmpty else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = SRT.cue(at: time.seconds, in: self.cues) ?? ""
                if next != self.caption { self.caption = next }
            }
        }
    }
}

/// Lightweight talk/transcript media player presented as a sheet over the
/// reader. A `[mm:ss]` timestamp click sets `model.talkPlayback`; this view
/// seeks the controller's player to that time. Re-seeking the same media keeps
/// the sheet up and just moves the playhead.
struct TalkPlayerView: View {
    @Bindable var model: AppModel
    /// Size of the reader area the player floats over, used to fit the enlarged
    /// video without overflowing.
    var availableSize: CGSize
    @Binding var enlarged: Bool
    @StateObject private var controller = TalkPlayerController()

    private static let compactWidth: CGFloat = 460

    /// 16:9 video size: compact is a fixed corner card; enlarged grows to fill
    /// the reader area (bounded by both width and height so it always fits).
    private var videoSize: CGSize {
        let chrome: CGFloat = 24 + 40   // overlay padding + header height
        let maxW = max(320, availableSize.width - 24)
        let maxH = max(200, availableSize.height - chrome)
        var w = enlarged ? maxW : min(Self.compactWidth, maxW)
        var h = w * 9 / 16
        if h > maxH { h = maxH; w = h * 16 / 9 }
        return CGSize(width: w, height: h)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottom) {
                AVPlayerViewRepresentable(player: controller.player)
                    .frame(width: videoSize.width, height: videoSize.height)
                if !controller.caption.isEmpty {
                    Text(controller.caption)
                        .font(.system(size: enlarged ? 16 : 13, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 10)
                        .padding(.horizontal, 16)
                }
            }
        }
        // A non-modal floating panel: the reader stays interactive so clicking
        // another `[mm:ss]` re-seeks this player (the seekToken path).
        .frame(width: videoSize.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: enlarged)
        .onAppear { if let pb = model.talkPlayback { controller.apply(pb) } }
        .onChange(of: model.talkPlayback?.seekToken) { _, _ in
            if let pb = model.talkPlayback { controller.apply(pb) }
        }
        .onDisappear { controller.teardown() }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
            Text(model.talkPlayback?.title ?? "")
                .font(Typo.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                enlarged.toggle()
            } label: {
                Image(systemName: enlarged
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(enlarged ? String(localized: "还原") : String(localized: "放大"))
            Button {
                model.closeTalkPlayback()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
    }
}

/// AppKit `AVPlayerView` wrapper. SwiftUI's `VideoPlayer` aborts at runtime in a
/// bare SPM executable ("failed to demangle superclass … AVPlayerView") because
/// its generic metadata over `AVPlayerView` can't be resolved without an app
/// bundle. Wrapping `AVPlayerView` directly sidesteps that and gives the native
/// inline transport controls.
private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
