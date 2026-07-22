import SwiftUI

/// Watch tab / home screen — "Warm brass" redesign (handoff direction 1a).
/// The active watch as a product hero, a connection + battery glance, and a
/// today-at-a-glance card. Degrades for hands-only Q hybrids (no face name).
struct DashboardView: View {
    @EnvironmentObject var watch: WatchManager
    @EnvironmentObject var registry: WatchRegistry
    @StateObject private var fitness = FitnessStore.shared
    // The same daily goal Settings writes to the watch.
    @AppStorage("stepGoal") private var stepGoal = 10000
    @State private var findingWatch = false
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var connectingSince: Date?
    @State private var carouselItem: CarouselItem?
    @State private var pairing = false

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    /// A stuck `.connecting` (watch out of range — iOS keeps a pending
    /// connect alive indefinitely) reads as "Disconnected" after this long,
    /// rather than showing "Connecting…" forever.
    private let connectingTimeout: TimeInterval = 60

    private var kind: WatchKind {
        registry.activeWatch?.kind ?? .hybridHR
    }

    /// The carousel is parked on the trailing "+" card — the face-name/kind
    /// caption and connection glance below it describe the previous active
    /// *watch*, not the add flow, so they'd be misleading here.
    private var isViewingAddCard: Bool { carouselItem == .add }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        header
                        hero.padding(.top, 10)
                        if !isViewingAddCard {
                            statusGlance.padding(.top, 16)
                            affordances
                        }
                        todaySection.padding(.top, 22)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12 + tabBarHeight)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Theme.accent)
        .onChange(of: watch.connectionState, initial: true) { _, state in
            if state == .connecting {
                if connectingSince == nil { connectingSince = Date() }
            } else {
                connectingSince = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if editingName {
                TextField("Name", text: $nameDraft, onCommit: commitNameEdit)
                    .font(Theme.serif(32))
                    .foregroundStyle(Theme.ink)
                    .submitLabel(.done)
            } else {
                Text(registry.activeWatch?.name ?? String(localized: "Watch"))
                    .font(Theme.serif(40))
                    .tracking(0.3)
                    .lineSpacing(0)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: 250, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(perform: beginNameEdit)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func beginNameEdit() {
        guard registry.activeWatchID != nil else { return }
        nameDraft = registry.activeWatch?.name ?? ""
        editingName = true
    }

    private func commitNameEdit() {
        defer { editingName = false }
        guard let id = registry.activeWatchID else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        registry.rename(id, to: trimmed)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 0) {
            WatchCarousel(scrolledItem: $carouselItem)

            if !isViewingAddCard {
                // Face name — HR only; hidden for hands-only Q hybrids.
                if kind.hasWatchfaces, let name = watch.activeWatchfaceName, !name.isEmpty {
                    Text(name.uppercased())
                        .font(Theme.mono(12, weight: .medium))
                        .tracking(0.6)
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                }

                Text("Fossil \(kind.displayName)")
                    .font(Theme.sans(15, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.sub)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Status glance

    private var statusGlance: some View {
        // Periodic tick so a stalled "Connecting…" flips to "Disconnected"
        // on its own once the timeout elapses, without a state change from
        // WatchManager to trigger a redraw.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            VStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { statusPills }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            connectionPill
                            if let battery = watch.batteryLevel { batteryPill(battery) }
                        }
                        
                        if watch.connectionState == .ready { findButton }
                    }
                }
                Text(syncLine)
                    .font(Theme.sans(12, relativeTo: .caption))
                    .foregroundStyle(Theme.sub)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder private var statusPills: some View {
        connectionPill
        if let battery = watch.batteryLevel { batteryPill(battery) }
        if watch.connectionState == .ready { findButton }
    }

    private var findButton: some View {
        Button {
            findWatch()
        } label: {
            HStack(spacing: 6) {
                if findingWatch {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(findingWatch ? String(localized: "Vibrating…") : String(localized: "Locate"))
                    .font(Theme.sans(13, weight: .semibold, relativeTo: .footnote))
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .pill()
        .disabled(findingWatch)
        .accessibilityLabel("Find watch")
        .accessibilityHint("Vibrates the watch so you can locate it")
    }

    private func findWatch() {
        findingWatch = true
        Task {
            do {
                if let confirmed = try await watch.findActiveWatchAndConfirm() {
                    await MainActor.run {
                        confirmed
                            ? ToastCenter.shared.success(
                                String(localized: "Found — confirmed on the watch"))
                            : ToastCenter.shared.error(
                                String(localized: "No response — vibration timed out"))
                    }
                }
            } catch {
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
            await MainActor.run { findingWatch = false }
        }
    }
    
    private func pair() {
        pairing = true
        Task {
            do {
                try await watch.performDevicePairing()
                await MainActor.run {
                    ToastCenter.shared.success(String(localized: "Pairing succeeded"))
                }
            } catch {
                await MainActor.run {
                    ToastCenter.shared.error(
                        String(localized: "Pairing: \(error.localizedDescription)"))
                }
            }
            await MainActor.run { pairing = false }
        }
    }

    
    private var isActiveReady: Bool {
        watch.connectionState == .ready
    }
    private var canManageHardware: Bool { isActiveReady && kind != .misfitQ }
    
    private var pairingAction: (() -> Void)? {
        guard canManageHardware, !pairing, !(watch.isDevicePaired ?? false) else { return nil }
        return { pair() }
    }

    private var connectionPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connState.dot)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(connState.halo, lineWidth: 3).scaleEffect(1.75))
            Text(connState.label)
                .font(Theme.sans(13, weight: .semibold, relativeTo: .footnote))
                .tracking(0.1)
                .foregroundStyle(Theme.ink)
        }
        .pill()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connState.label)
        .onTapGesture {
            self.pairingAction?()
        }
    }

    private func batteryPill(_ level: Int) -> some View {
        HStack(spacing: 6) {
            BatteryGlyph(level: level, fill: batteryColor(level))
            Text("\(level)%")
                .font(Theme.mono(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
        .pill()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(level)%")
    }

    private func batteryColor(_ level: Int) -> Color {
        if level <= 15 { return Theme.danger }
        if level <= 30 { return Theme.warn }
        return Theme.ink
    }

    /// Connection state collapsed to the visual states in the design. A
    /// `.connecting` that's been stuck past `connectingTimeout` (watch out
    /// of range — the pending CoreBluetooth connect never times out on its
    /// own) reads as "Disconnected" instead of "Connecting…" forever.
    private var connState: (dot: Color, halo: Color, label: String) {
        switch watch.connectionState {
        case .ready:
            if watch.isDevicePaired ?? false {
                return (Theme.success, Theme.success.opacity(0.16), String(localized: "Connected"))
            }
            return (Theme.warn, Theme.warn.opacity(0.16), String(localized: "Unpaired"))
        case .bluetoothOff:
            return (Theme.warn, Theme.warn.opacity(0.16), String(localized: "Bluetooth off"))
        case .connecting where isConnectingStalled:
            return (Theme.danger, Theme.danger.opacity(0.16), String(localized: "Disconnected"))
        case .connecting, .initializing, .authenticating, .scanning:
            return (Theme.warn, Theme.warn.opacity(0.16), watch.connectionState.label)
        case .disconnected, .failed:
            return (Theme.danger, Theme.danger.opacity(0.16), String(localized: "Disconnected"))
        }
    }

    private var isConnectingStalled: Bool {
        guard let since = connectingSince else { return false }
        return Date().timeIntervalSince(since) > connectingTimeout
    }

    private var syncLine: String {
        guard watch.connectionState != .bluetoothOff else {
            return String(localized: "Turn on Bluetooth to reconnect")
        }
        guard let last = fitness.lastSync(for: registry.activeWatchID) else {
            return String(localized: "Not synced yet")
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return String(localized: "Synced \(f.localizedString(for: last, relativeTo: Date()))")
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

// MARK: - Pill styling

private extension View {
    func pill() -> some View {
        padding(.vertical, 7)
            .padding(.horizontal, 13)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
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
                    Text("\(Int((progress * 100).rounded()))%")
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

// MARK: - Battery glyph (outline + level fill), matching the handoff SVG.

private struct BatteryGlyph: View {
    let level: Int
    let fill: Color

    var body: some View {
        // Drawn in the handoff's 26×13 viewBox, then scaled to 22×11.
        Canvas { ctx, _ in
            let body = CGRect(x: 1, y: 1, width: 21, height: 11)
            ctx.stroke(Path(roundedRect: body, cornerRadius: 3.2),
                       with: .color(Theme.ink.opacity(0.3)), lineWidth: 1)
            let nub = CGRect(x: 23.4, y: 4.2, width: 1.8, height: 4.6)
            ctx.fill(Path(roundedRect: nub, cornerRadius: 0.9),
                     with: .color(Theme.ink.opacity(0.3)))
            let w = CGFloat(max(0, min(100, level))) / 100 * 17
            let inner = CGRect(x: 2.8, y: 2.8, width: w, height: 7.4)
            ctx.fill(Path(roundedRect: inner, cornerRadius: 1.6), with: .color(fill))
        }
        .frame(width: 26, height: 13)
        .scaleEffect(22.0 / 26.0)
        .frame(width: 22, height: 11)
    }
}
