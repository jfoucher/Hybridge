import Foundation
import AVFoundation
import AudioToolbox
import UIKit
import UserNotifications

/// Find-my-phone playback, triggered by the watch's `ringMyPhone` JSON event
/// (already parsed/acked in WatchActions — this fills in the missing sound).
///
/// **Foreground only.** The app deliberately does not declare the `audio`
/// background mode: that mode is for media playback, and using it to keep a
/// find-my-phone tone alive is what App Store guideline 2.5.4 ("background
/// services only for their intended purposes") is aimed at. Without it iOS
/// will not activate a playback session from the background at all, and it
/// suspends an already-playing one as soon as the app leaves the foreground.
///
/// So the behaviour splits:
/// - **Foreground:** ring on loop (overriding the silent switch) + vibrate,
///   auto-stopping after 60s.
/// - **Background:** no audio attempt — it cannot work. A local notification
///   with the default sound is posted instead, which does make noise even
///   while the app is suspended, and tapping it opens the app so the user can
///   ring properly.
///
/// The BLE event itself still arrives in the background (bluetooth-central
/// keeps waking us for characteristic notifications while connected), so the
/// watch button is never dead — only the tone is. Force-quitting the app
/// stops BLE wakes entirely, the same platform limitation as background
/// activity sync, so nothing reaches the phone until the next manual launch.
final class PhoneFinder {
    static let shared = PhoneFinder()

    private var player: AVAudioPlayer?
    private var vibrateTimer: Timer?
    private var safetyTimer: Timer?

    private init() {
        // Audio is suspended by iOS the moment we background, but the player
        // object keeps reporting `isPlaying` — which the watch-button toggle
        // reads to decide between start and stop. Tear down explicitly so
        // `isRinging` never claims we are ringing when nothing is audible.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.player != nil else { return }
                WatchManager.shared.addLog("PhoneFinder: stopped (app backgrounded)")
                self.stopOnMain()
            }
    }

    var isRinging: Bool { player?.isPlaying ?? false }

    func start() {
        DispatchQueue.main.async { self.startOnMain() }
    }

    func stop() {
        DispatchQueue.main.async { self.stopOnMain() }
    }

    private func startOnMain() {
        guard player?.isPlaying != true else { return }

        // `.background` is the only state where playback definitively cannot
        // start. `.inactive` (app switcher, an incoming-call banner, Control
        // Centre pulled down) still permits it, so don't test for `.active`.
        guard UIApplication.shared.applicationState != .background else {
            WatchManager.shared.addLog("PhoneFinder: backgrounded — notifying instead of ringing")
            postCannotRingNotification()
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // .playback (not .mixWithOthers): ducks/interrupts whatever's
            // playing and overrides the silent switch.
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            WatchManager.shared.addLog("PhoneFinder: session activation failed: \(error.localizedDescription)")
            postCannotRingNotification()
            return
        }

        guard let url = Bundle.main.url(forResource: "ring", withExtension: "caf") else {
            WatchManager.shared.addLog("PhoneFinder: ring.caf resource missing")
            return
        }
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.numberOfLoops = -1
            newPlayer.volume = 1.0
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer

            vibrateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
            // Auto-stop even if the watch never sends "off" (BLE drop, etc.).
            safetyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                self?.stopOnMain()
            }
            WatchManager.shared.addLog("PhoneFinder: ringing")
        } catch {
            WatchManager.shared.addLog("PhoneFinder failed to start: \(error.localizedDescription)")
        }
    }

    private func stopOnMain() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        vibrateTimer?.invalidate()
        vibrateTimer = nil
        safetyTimer?.invalidate()
        safetyTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        clearNotification()
        WatchManager.shared.addLog("PhoneFinder: stopped")
    }

    private static let notificationId = "phoneFinder.ringing"

    /// The background substitute for the tone. A local notification's sound
    /// plays even while the app is suspended, so this is what the user
    /// actually hears when they press the watch button with the phone in a
    /// pocket; opening the app then rings properly.
    private func postCannotRingNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Finding your phone")
        content.body = String(localized: "Tap to open Hybridge and ring your phone.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.notificationId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func clearNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationId])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationId])
    }
}
