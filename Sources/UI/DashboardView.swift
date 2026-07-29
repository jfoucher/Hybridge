import SwiftUI

/// Watch tab / home screen — "Warm brass" redesign (handoff direction 1a).
/// The active watch as a product hero and a today-at-a-glance card. The
/// per-watch identity and glance (name, face name, family, connection,
/// battery, Locate, last sync) live inside `WatchCarousel`'s cards so they
/// slide with the swipe; only the transfer progress and today's totals —
/// which aren't per-card — are laid out here.
struct DashboardView: View {
    @EnvironmentObject var watch: WatchManager
    @StateObject private var fitness = FitnessStore.shared
    // The same daily goal Settings writes to the watch.
    @AppStorage("stepGoal") private var stepGoal = 10000
    @State private var carouselItem: CarouselItem?

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    /// The carousel is parked on the trailing "+" card — a transfer running
    /// on the previous active *watch* isn't what the add flow is about.
    private var isViewingAddCard: Bool { carouselItem == .add }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    // The carousel is deliberately outside the 22pt page
                    // margin: its cards are already inset by the peek, and the
                    // extra width is what keeps a card's status pills on one
                    // line.
                    VStack(spacing: 0) {
                        WatchCarousel(scrolledItem: $carouselItem)
                            .padding(.top, 12)
                        if !isViewingAddCard {
                            affordances.padding(.horizontal, 22)
                        }
                        todaySection
                            .padding(.top, 22)
                            .padding(.horizontal, 22)
                    }
                    .padding(.bottom, 12 + tabBarHeight)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .refreshable {
                    await refreshFromWatch()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Theme.accent)
    }

    /// Pull-to-refresh: forces a full read off the watch (config/battery,
    /// activity file, installed apps + watchface preview) rather than
    /// waiting on the periodic-maintenance throttle.
    private func refreshFromWatch() async {
        guard watch.connectionState != .bluetoothOff else {
            ToastCenter.shared.error(String(localized: "Turn on Bluetooth to sync"))
            return
        }
        // Run the refresh in an *unstructured* Task and await its value. The
        // refresh emits @Published updates (battery/steps/apps) that re-render
        // this view, and SwiftUI reacts by cancelling the `.refreshable`
        // gesture task mid-flight. When the sync ran directly in that task,
        // `Task.checkCancellation()` tripped right before the FitnessStore
        // merge — so the file downloaded but "Synced …" never advanced. An
        // unstructured Task doesn't inherit that cancellation, so the merge
        // (and the on-watch file delete) complete; awaiting `.value` keeps the
        // pull-to-refresh spinner up until the real work is done.
        let work = Task {
            // Fossil hybrids drop BLE when idle, so a pull often lands while
            // the watch is reconnecting — wait it out, as the sync intent does.
            guard await watch.waitUntilReady(timeout: 20) else {
                await MainActor.run {
                    ToastCenter.shared.error(
                        String(localized: "Couldn't reach the watch — make sure it's nearby"))
                }
                return
            }
            try await watch.forceFullRefresh()
        }
        do {
            try await work.value
        } catch is CancellationError {
            // forceFullRefresh itself observed a real teardown — not a failure.
        } catch {
            await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
        }
    }

    // MARK: Transfer affordance (retained behaviour)

    @ViewBuilder private var affordances: some View {
        if let progress = watch.uploadProgress {
            VStack(spacing: 6) {
                ProgressView(value: progress)
                    .tint(Theme.accent)
                Text("Transferring…")
                    .font(Theme.sans(12, relativeTo: .caption))
                    .foregroundStyle(Theme.sub)
            }
            .padding(.top, 16)
        }
    }

    // MARK: Today

    private var todaySection: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(Theme.serif(22))
                    .tracking(0.3)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("Goal \(stepGoal.grouped)")
                    .font(Theme.mono(11, weight: .regular))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.sub)
            }
            .padding(.horizontal, 4)

            metricsCard
        }
    }

    private var metricsCard: some View {
        HStack(spacing: 0) {
            StepsTile(steps: todaySteps, goal: stepGoal)
                .frame(maxWidth: .infinity)
            tileDivider
            MetricTile(icon: "flame.fill",
                       value: fitness.calories(onDay: Date()).formatted(),
                       label: "kcal")
                .frame(maxWidth: .infinity)
            tileDivider
            MetricTile(icon: "bolt.fill",
                       value: fitness.activeMinutes(onDay: Date()).formatted(),
                       label: "active min")
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1))
        )
        .themeShadow(Theme.cardShadow)
    }

    private var tileDivider: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    /// One user-wide total across every registered watch. Each watch's live
    /// counter tops up only that watch's synced samples, avoiding duplicates.
    private var todaySteps: Int {
        fitness.stepsIncludingLive(onDay: Date())
    }
}

private extension Int {
    /// Thousands-grouped, e.g. 10000 → "10,000".
    var grouped: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

// MARK: - Steps ring tile

private struct StepsTile: View {
    let steps: Int
    let goal: Int
    @State private var animated: CGFloat = 0

    private var progress: CGFloat {
        CGFloat(max(0, min(1, Double(steps) / Double(max(goal, 1)))))
    }
    private var goalMet: Bool { progress >= 1 }
    private var ringColor: Color { goalMet ? Theme.success : Theme.accent }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Theme.accentSoft, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: animated)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(steps.grouped)
                        .font(Theme.mono(16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 8)
                    Text("\(Double(progress), format: .percent.precision(.fractionLength(0)))")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.sub)
                }
            }
            .frame(width: 72, height: 72)

            Text("steps")
                .font(Theme.sans(12, weight: .medium, relativeTo: .caption))
                .foregroundStyle(Theme.sub)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { animated = progress }
        }
        .onChange(of: progress) { _, new in
            withAnimation(.easeOut(duration: 0.6)) { animated = new }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Steps")
        .accessibilityValue("\(steps.grouped) of \(goal.grouped), \(Int((progress * 100).rounded())) percent")
    }
}

// MARK: - Simple metric tile (icon + number + label)

private struct MetricTile: View {
    let icon: String
    let value: String
    let label: LocalizedStringResource

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(Theme.mono(20, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(label)
                .font(Theme.sans(12, weight: .medium, relativeTo: .caption))
                .foregroundStyle(Theme.sub)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(value)
    }
}
