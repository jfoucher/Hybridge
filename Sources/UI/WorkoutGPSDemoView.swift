import SwiftUI
import CoreLocation
import UIKit

/// Exercises the watch-workout GPS path directly from the app: start a
/// foreground GPS session, lock the phone, watch the distance keep counting
/// with the blue background-location indicator showing, then stop.
///
/// Two reasons it exists:
/// 1. The real trigger is a *watch* starting a workout, which App Review can't
///    reproduce without a paired Fossil Hybrid. This makes the `location`
///    background mode observable on a bare device — tap, lock, walk, see the
///    distance and the blue indicator. Point the reviewer here.
/// 2. It's a genuinely useful "does my GPS work?" check for the user.
struct WorkoutGPSDemoView: View {
    @StateObject private var tracker = WorkoutLocationTracker.shared
    @State private var status = WorkoutLocationTracker.shared.authorizationStatus

    private var distanceText: String {
        let m = tracker.liveDistanceMeters
        if m >= 1000 {
            let km = (m / 1000).formatted(.number.precision(.fractionLength(2)))
            return String(localized: "\(km) km")
        }
        return String(localized: "\(Int(m.rounded())) m")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Distance", value: distanceText)
                    .font(.system(.body, design: .monospaced))
                LabeledContent("State", value: tracker.isRunning
                               ? String(localized: "Recording") : String(localized: "Stopped"))
                    .foregroundStyle(tracker.isRunning ? Theme.accent : Theme.sub)
            } footer: {
                Text("Start recording, then lock your phone or switch apps. Distance keeps counting in the background, and iOS shows the blue location indicator while it does — that's the `location` background mode at work. It stops the moment you tap Stop.")
            }

            Section {
                if tracker.isRunning {
                    Button(role: .destructive) {
                        tracker.stopDemoWorkout()
                    } label: {
                        Label("Stop recording", systemImage: "stop.fill")
                    }
                } else {
                    Button {
                        tracker.startDemoWorkout()
                    } label: {
                        Label("Start recording", systemImage: "location.fill")
                    }
                    .disabled(status == .denied || status == .restricted)
                }
            } footer: {
                switch status {
                case .denied, .restricted:
                    Text("Location access is off for Hybridge. Enable it in Settings to record distance.")
                        .foregroundStyle(Theme.danger)
                case .notDetermined:
                    Text("Recording will ask for “When in Use” location access — that's all this needs.")
                case .authorizedWhenInUse:
                    Text("Authorized “When in Use” — a session started here (in the foreground) continues after you lock the phone.")
                default:
                    EmptyView()
                }
            }
        }
        .navigationTitle("Workout GPS")
        .themedList()
        .tint(Theme.accent)
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            status = tracker.authorizationStatus
        }
        .onAppear { status = tracker.authorizationStatus }
    }
}
