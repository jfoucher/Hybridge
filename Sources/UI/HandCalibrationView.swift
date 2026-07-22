import SwiftUI

/// Physical hand calibration: take control of the hands and move them to
/// 12:00, let the user nudge the selected hand until it points exactly at 12,
/// then save the offset as the new zero. Leaving the screen without saving
/// discards the adjustment.
struct HandCalibrationView: View {
    @EnvironmentObject var watch: WatchManager
    @EnvironmentObject var registry: WatchRegistry
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var skin = WatchSkinStore.shared

    private enum Hand: CaseIterable {
        case hour, minute, sub

        var title: LocalizedStringResource {
            switch self {
            case .hour: "Hour"
            case .minute: "Minute"
            case .sub: "Small"
            }
        }
    }

    @State private var hand: Hand = .minute
    @State private var busy = false
    @State private var calibrating = false

    /// The Q hybrids have a physical sub-eye (hand 3); the HR draws its
    /// sub-dials on the display, so it only calibrates hour and minute.
    private var hasSubEye: Bool {
        (registry.activeWatch?.kind ?? .hybridHR).hasSubEye
    }

    private var hands: [Hand] {
        hasSubEye ? Hand.allCases : [.hour, .minute]
    }

    var body: some View {
        Form {
            Section {
                Group {
                    if skin.hasCase {
                        // Skin artwork has the hands at 12 by definition
                        // (pivot-centred, pointing up), so angle 0 shows
                        // exactly the target position over the live face.
                        WatchCompositeView(skin: skin, face: watch.activeWatchfaceImage,
                                           hourAngle: 0, minuteAngle: 0)
                    } else {
                        drawnTarget
                    }
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } header: {
                Text("Target position")
            } footer: {
                Text(hasSubEye
                     ? String(localized: "When saving, both main hands must physically point straight up at 12 o'clock, and the small hand at its dial's top marker.")
                     : String(localized: "When saving, both hands must physically point straight up at 12 o'clock, like shown above."))
            }

            Section {
                Picker("Hand", selection: $hand) {
                    ForEach(hands, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)

                HStack {
                    ForEach([-100, -10, -1, 1, 10, 100], id: \.self) { step in
                        Button(step > 0 ? "+\(step)" : "\(step)") {
                            move(step)
                        }
                        .buttonStyle(.bordered)
                        .font(.footnote.monospacedDigit())
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.plain)   // keep taps on the buttons, not the row
                .disabled(busy || !calibrating)
            } header: {
                Text("Adjust")
            } footer: {
                Text(hasSubEye
                     ? String(localized: "The watch moved all hands to what it thinks is their zero position. Nudge the selected hand by degrees until it matches, then save.")
                     : String(localized: "The watch moved both hands to what it thinks is 12 o'clock. Nudge the selected hand by degrees until it matches the target above, then save."))
            }

            Section {
                Button {
                    finish(save: true)
                } label: {
                    if busy {
                        HStack { ProgressView(); Text("Working…") }
                    } else {
                        Label("Save calibration", systemImage: "checkmark.circle")
                    }
                }
                .disabled(busy || !calibrating)
            } footer: {
                Text("Going back without saving discards the adjustment and re-syncs the hands to the current time.")
            }
        }
        .navigationTitle("Calibrate hands")
        .themedList()
        .navigationBarTitleDisplayMode(.inline)
        .task { await start() }
        .onDisappear {
            // Back navigation without saving: give the hands back to the
            // watch so they don't stay stuck at 12.
            guard calibrating else { return }
            calibrating = false
            Task { try? await watch.endHandCalibration(save: false) }
        }
    }

    /// Fallback illustration when no skin artwork is available: the live
    /// face (or a plain dial) with two drawn hands pointing at 12.
    private var drawnTarget: some View {
        ZStack {
            Circle().fill(Color(white: 0.1))
            if let face = watch.activeWatchfaceImage {
                Image(uiImage: face)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFill()
                    .clipShape(Circle())
            }
            hand(width: 7, length: 55)    // hour
            hand(width: 5, length: 80)    // minute
            Circle().fill(Color(white: 0.85)).frame(width: 14, height: 14)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func hand(width: CGFloat, length: CGFloat) -> some View {
        Capsule()
            .fill(Color(white: 0.85))
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .shadow(radius: 1, y: 1)
    }

    private func start() async {
        guard !calibrating else { return }
        busy = true
        do {
            try await watch.startHandCalibration()
            calibrating = true
        } catch {
            await MainActor.run {
                ToastCenter.shared.error(
                    String(localized: "Could not start calibration: \(error.localizedDescription)"))
            }
        }
        busy = false
    }

    private func move(_ degrees: Int) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                switch hand {
                case .hour: try await watch.moveHands(hour: degrees)
                case .minute: try await watch.moveHands(minute: degrees)
                case .sub: try await watch.moveHands(sub: degrees)
                }
            } catch {
                await MainActor.run {
                    ToastCenter.shared.error(
                        String(localized: "Move failed: \(error.localizedDescription)"))
                }
            }
            await MainActor.run { busy = false }
        }
    }

    private func finish(save: Bool) {
        busy = true
        calibrating = false   // onDisappear must not release a second time
        Task {
            do {
                try await watch.endHandCalibration(save: save)
                await MainActor.run {
                    ToastCenter.shared.success(String(localized: "Calibration saved"))
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    ToastCenter.shared.error(error.localizedDescription)
                    calibrating = true
                }
            }
            await MainActor.run { busy = false }
        }
    }
}
