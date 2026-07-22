import Foundation
import MediaPlayer
import UIKit

/// Q-watch music transport + volume. On the Hybrid HR, iOS-native AMS drives
/// media for whatever app is playing the moment the watch is bonded, so the
/// app takes no part. The older Q hybrids have no AMS client: when a button is
/// assigned to music control or volume (or a multi-press is mapped to a media
/// action), the watch sends a 0x05 action frame on 3dda0006 and the app
/// executes it here (GB: FossilWatchAdapter.java:855-930).
///
/// Only Apple Music is driven (`MPMusicPlayerController.systemMusicPlayer`);
/// controlling another app's playback would need the private MediaRemote API.
final class MusicController {
    static let shared = MusicController()

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var volumeView: MPVolumeView?

    private init() {}

    // MARK: - Watch -> phone (char0006, 4-byte frame, value[1] == 0x05)

    /// `action` per GB table: 0x02 play/pause, 0x03 next, 0x04 previous,
    /// 0x05 volume up, 0x06 volume down. No consent gate — the user opted in
    /// by assigning the Q button function (GB has no gate on this path either).
    func performWatchAction(_ action: UInt8) {
        DispatchQueue.main.async {
            switch action {
            case 0x02:
                self.player.playbackState == .playing ? self.player.pause() : self.player.play()
            case 0x03:
                self.player.skipToNextItem()
            case 0x04:
                self.player.skipToPreviousItem()
            case 0x05:
                self.adjustVolume(by: 1.0 / 16.0)
            case 0x06:
                self.adjustVolume(by: -1.0 / 16.0)
            default:
                return
            }
            // GB echoes the received command back as the ack.
            WatchManager.shared.write(Data([0x02, 0x05, action, 0x00]), to: FossilUUID.char0006)
        }
    }

    // MARK: - Volume (foreground-only best effort; iOS has no background API)

    private func adjustVolume(by delta: Float) {
        guard UIApplication.shared.applicationState == .active else {
            WatchManager.shared.addLog("Volume change ignored — app in background (iOS limitation)")
            return
        }
        guard let slider = systemVolumeSlider() else { return }
        slider.value = max(0, min(1, slider.value + delta))
    }

    /// MPVolumeView must be attached to a window for its slider to actually
    /// drive the system volume, hence the off-screen frame instead of just
    /// `isHidden`.
    private func systemVolumeSlider() -> UISlider? {
        if volumeView == nil {
            let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
                window.addSubview(view)
            }
            volumeView = view
        }
        return volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }
}
