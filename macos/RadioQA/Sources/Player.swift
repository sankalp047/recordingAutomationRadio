import AVFoundation
import Observation

/// Thin AVPlayer wrapper. The API supports HTTP Range, so seeking does not
/// download the whole hour first.
@MainActor
@Observable
final class Player {
    private(set) var current: Recording?
    private(set) var isPlaying = false
    var position: Double = 0
    private(set) var duration: Double = 0

    private var player: AVPlayer?
    private var observer: Any?

    func play(_ rec: Recording, url: URL) {
        stop()
        current = rec
        duration = rec.durationSeconds
        let p = AVPlayer(url: url)
        player = p
        observer = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated { self?.position = t.seconds }
        }
        p.play()
        isPlaying = true
    }

    func toggle() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        position = seconds
    }

    func skip(_ delta: Double) {
        seek(to: min(max(0, position + delta), duration))
    }

    func stop() {
        if let o = observer { player?.removeTimeObserver(o); observer = nil }
        player?.pause()
        player = nil
        isPlaying = false
        position = 0
    }

    static func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
