import SwiftUI
import UIKit

@main
struct HybridgeApp: App {
    @StateObject private var watch = WatchManager.shared
    @StateObject private var registry = WatchRegistry.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Theme.configureAppearance()
        WidgetBridge.shared.start()
        HealthKitExporter.shared.startAutoExportObserving(FitnessStore.shared)
        BackgroundRefresher.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(watch)
                .environmentObject(registry)
                .onOpenURL { url in
                    // A .hbface from Files/Messages/AirDrop. RootTabView
                    // brings the Faces tab forward; WatchfacesView consumes it.
                    WatchfaceImportRouter.shared.pendingImportURL = url
                }
                .onChange(of: scenePhase) { _, phase in
                    // Capture final state before suspension, and refresh
                    // staleness math on return — the bridge's own publishers
                    // don't fire while the app is backgrounded.
                    if phase == .background || phase == .active {
                        WidgetBridge.shared.flushNow()
                    }
                    if phase == .background {
                        BackgroundRefresher.shared.scheduleNext()
                    }
                    if phase == .active {
                        Task { await QuietHoursManager.shared.evaluateAll() }
                        // A background launch while the device was locked leaves
                        // FitnessStore with writes blocked (the protected archive
                        // couldn't be read). The unlock notification that clears
                        // it is missed once iOS suspends the app, so re-attempt
                        // the load on every foreground — otherwise sync silently
                        // no-ops and "Synced … ago" freezes. No-op when not blocked.
                        Task { await FitnessStore.shared.retryLoadIfBlocked() }
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var watch: WatchManager
    @EnvironmentObject var registry: WatchRegistry
    @State private var showKeyEntry = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: OnboardingView.seenKey)

    /// Capabilities of the active watch drive which tabs/screens exist.
    /// Persisted in the registry, so the UI is right even while disconnected.
    private var kind: WatchKind {
        registry.activeWatch?.kind ?? .hybridHR
    }

    var body: some View {
        Group {
            if registry.isEmpty {
                // First run (or every watch forgotten): find a watch first.
                ScanView()
            } else {
                RootTabView(hasFaces: kind.hasWatchfaces)
            }
        }
        .tint(Theme.accent)
        .background {
            // Attaching from a plain view (rather than .overlay) so the
            // toast window is created once a scene exists, independent of
            // this view's own layer — see ToastWindowController.
            Color.clear.onAppear {
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    ToastWindowController.attach(to: scene)
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { watch.awaitingAdoptionConfirm },
            set: { _ in }   // dismissal is driven by the flag itself
        )) {
            AdoptionConfirmView()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $showKeyEntry) {
            if let id = registry.activeWatchID {
                KeyEntryView(watchID: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchNeedsAuthKey)) { _ in
            // WatchManager starts init itself when a key exists (or none is
            // needed — Q watches are unencrypted); the UI only needs to
            // prompt for a connected HR's missing key.
            if let id = WatchRegistry.activeWatchIDSync(), KeychainStore.loadKey(for: id) == nil {
                showKeyEntry = true
            }
        }
    }
}
