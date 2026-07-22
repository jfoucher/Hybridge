import SwiftUI

/// Shown full-screen while a freshly added watch buzzes and waits for the
/// user to press its middle button — the same physical confirmation the
/// official app requires so you can't accidentally add a stranger's nearby
/// watch. Dismisses itself when `WatchManager.awaitingAdoptionConfirm` clears
/// (the watch confirmed, timed out, or the user cancelled).
struct AdoptionConfirmView: View {
    @EnvironmentObject var watch: WatchManager
    @EnvironmentObject var registry: WatchRegistry

    private var watchName: String {
        registry.activeWatch?.name ?? String(localized: "your watch")
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating)

                VStack(spacing: 12) {
                    Text("Confirm it's your watch")
                        .font(Theme.serif(28))
                        .tracking(0.3)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    Text("\(watchName) should be vibrating now. Press its middle button to finish adding it.")
                        .font(Theme.sans(15, relativeTo: .body))
                        .foregroundStyle(Theme.sub)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                ProgressView()
                    .tint(Theme.accent)
                    .padding(.top, 4)

                Spacer()

                Button {
                    watch.cancelAdoptionConfirm()
                } label: {
                    Text("Cancel")
                        .font(Theme.sans(16, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Theme.card))
                        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .interactiveDismissDisabled()
    }
}
