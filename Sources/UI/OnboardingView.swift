import SwiftUI

/// First-run walkthrough: what the app is, where the auth key comes from,
/// what to expect from pairing, and which permissions get requested when.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var page = 0

    static let seenKey = "onboardingSeen"

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                authKey.tag(1)
                pairing.tag(2)
                permissions.tag(3)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < 3 {
                    withAnimation { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page < 3 ? String(localized: "Continue") : String(localized: "Get started"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.top, 8)

            Button("Skip") { finish() }
                .font(.footnote)
                .padding(.vertical, 8)
        }
        .interactiveDismissDisabled()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        dismiss()
    }

    private func pageLayout(icon: String, title: LocalizedStringResource,
                            @ViewBuilder content: @escaping () -> some View) -> some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: verticalSizeClass == .compact ? 10 : 16) {
                    Image(systemName: icon)
                        .font(.system(size: verticalSizeClass == .compact ? 36 : 56))
                        .foregroundStyle(.tint)
                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    content()
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 28)
                .padding(.vertical, verticalSizeClass == .compact ? 14 : 28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
    }

    private var welcome: some View {
        pageLayout(icon: "applewatch.radiowaves.left.and.right", title: "Fossil Hybrid HR") {
            Text("An unofficial companion for the Fossil Hybrid HR: watchfaces, alarms, settings, notifications, fitness sync and more.")
        }
    }

    private var authKey: some View {
        pageLayout(icon: "key.horizontal", title: "You need your watch's key") {
            VStack(spacing: 12) {
                Text("Every watch has a secret 16-byte authentication key. Without Fossil's servers it can't be fetched automatically — you have to bring your own:")
                Text("• Obtained from the Fossil API\n• Captured from the official app\n• From a backup of either app")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("The app asks for it when you first connect a watch and stores it in the iOS Keychain — each watch keeps its own key.")
            }
        }
    }

    private var pairing: some View {
        pageLayout(icon: "link", title: "Pairing = notifications") {
            Text("After connecting, pair the watch with iOS (Settings → iPhone pairing). iOS shows a pairing dialog, then asks to share notifications. Once bonded, the watch receives calls, messages and music info directly from iOS — even with this app closed.")
        }
    }

    private var permissions: some View {
        pageLayout(icon: "hand.raised", title: "Permissions, when needed") {
            Text("Bluetooth is required up front. Everything else is asked only when you enable it: location for weather and workout GPS, calendar for event sync, Apple Health for fitness export, notifications for the low-battery alert.")
        }
    }
}
