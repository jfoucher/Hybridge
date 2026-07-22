@preconcurrency import SwiftUI
@preconcurrency import UIKit

/// Item identity for the dashboard's horizontal watch carousel: one card per
/// known watch (first-added → last, `WatchRegistry.watches` order), plus a
/// trailing "add watch" card.
enum CarouselItem: Hashable {
    case watch(UUID)
    case add
}

/// Swipeable hero replacing the old header Menu switcher (audit finding M6):
/// watches ordered first-added → last, both neighbors partially visible so
/// the swipe is discoverable, and a full swipe activates the next watch via
/// `WatchManager.switchTo`. Tapping the centered card opens the management
/// sheet (rename / auth key / disconnect / forget); tapping a peeked
/// neighbor scrolls it to center instead of switching immediately. The
/// trailing "+" card starts the existing add-watch scan flow.
///
/// `scrolledItem` is owned by the parent (`DashboardView`) rather than kept
/// internal: the dashboard needs to know when the carousel is parked on the
/// "Add a watch" card so it can hide the face-name/kind caption and the
/// connection glance, which describe the previous *watch*, not the add flow.
struct WatchCarousel: View {
    @EnvironmentObject var watch: WatchManager
    @EnvironmentObject var registry: WatchRegistry
    @Binding var scrolledItem: CarouselItem?

    @State private var managingWatch: KnownWatch?
    @State private var showAddSheet = false
    @State private var switchTask: Task<Void, Never>?
    // Per-watch skin loaders for the non-active cards, keyed by watch id —
    // `WatchSkinStore.shared` always tracks the active watch, so a peeked
    // card needs its own store pinned to that specific watch or it would
    // show whichever skin `shared` currently has loaded (the previous
    // watch's), not its own.
    @State private var pinnedSkinStores: [UUID: WatchSkinStore] = [:]

    private let peekInset: CGFloat = 40
    private let cardSpacing: CGFloat = 14
    private let cardHeight: CGFloat = 258

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: cardSpacing) {
                    ForEach(registry.watches) { known in
                        let isActive = known.id == registry.activeWatchID
                        WatchCard(known: known,
                                  isActive: isActive,
                                  face: isActive ? watch.activeWatchfacePreviewImage : nil,
                                  skin: isActive ? WatchSkinStore.shared : pinnedSkinStore(for: known.id))
                            .containerRelativeFrame(.horizontal)
                            .id(CarouselItem.watch(known.id))
                            .onTapGesture { handleTap(on: known) }
                    }
                    AddWatchCard()
                        .containerRelativeFrame(.horizontal)
                        .id(CarouselItem.add)
                        .onTapGesture { showAddSheet = true }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledItem)
            .contentMargins(.horizontal, peekInset, for: .scrollContent)
            .frame(height: cardHeight)

            pageDots
        }
        .onAppear {
            if scrolledItem == nil {
                scrolledItem = registry.activeWatchID.map(CarouselItem.watch)
            }
            refreshPinnedSkinStores()
        }
        .onChange(of: scrolledItem) { _, item in
            // `scrollPosition(id:)` reports the nearest item continuously as
            // the drag crosses the halfway point, not only once the swipe
            // has actually settled — switching immediately on every change
            // flipped the still-active card to its dimmed peek mock mid-drag,
            // before the user had committed to anything. Debounce so a real
            // switch only fires once the position has held still for a
            // moment (a finished swipe, or a released settle animation).
            switchTask?.cancel()
            switchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                guard case .watch(let id) = item, id != registry.activeWatchID else { return }
                watch.switchTo(id)
            }
        }
        .onChange(of: registry.activeWatchID) { old, new in
            // The watch that just stopped being active may have had its skin
            // edited (Settings → Watch appearance) while it was still using
            // the live `shared` store — refresh its pinned copy so a later
            // peek shows the edit, not a stale snapshot from before it was
            // ever pinned.
            if let old { pinnedSkinStores[old] = WatchSkinStore(watchID: old) }
            refreshPinnedSkinStores()
            let target: CarouselItem? = new.map(CarouselItem.watch)
            guard target != scrolledItem else { return }
            withAnimation { scrolledItem = target }
        }
        .onChange(of: registry.watches) { _, _ in refreshPinnedSkinStores() }
        .onDisappear { switchTask?.cancel() }
        .sheet(item: $managingWatch) { known in
            WatchManageSheet(known: known)
        }
        .sheet(isPresented: $showAddSheet) {
            ScanView(addMode: true)
        }
    }

    private func handleTap(on known: KnownWatch) {
        if known.id == registry.activeWatchID {
            managingWatch = known
        } else {
            withAnimation { scrolledItem = .watch(known.id) }
        }
    }

    /// Looks up (never mutates state — safe to call from the view body) the
    /// pinned skin loader for a non-active watch, falling back to a fresh
    /// one-off instance for the rare frame where `refreshPinnedSkinStores()`
    /// hasn't populated the cache yet (e.g. the very first render).
    private func pinnedSkinStore(for id: UUID) -> WatchSkinStore {
        pinnedSkinStores[id] ?? WatchSkinStore(watchID: id)
    }

    private func refreshPinnedSkinStores() {
        let rosterIDs = Set(registry.watches.map(\.id))
        pinnedSkinStores = pinnedSkinStores.filter { rosterIDs.contains($0.key) }
        for id in rosterIDs where id != registry.activeWatchID && pinnedSkinStores[id] == nil {
            pinnedSkinStores[id] = WatchSkinStore(watchID: id)
        }
    }

    /// One dot per watch plus a small "+" standing in for the trailing add
    /// card — reinforces the swipe alongside the neighbor peek. Highlights
    /// whichever card is currently scrolled into view, not the true active
    /// watch (those two lag apart during the switch-commit debounce).
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(registry.watches) { known in
                Circle()
                    .fill(scrolledItem == .watch(known.id) ? Theme.accent : Theme.line)
                    .frame(width: 6, height: 6)
            }
            Image(systemName: "plus")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(scrolledItem == .add ? Theme.accent : Theme.line)
                .frame(width: 6, height: 6)
        }
        .accessibilityHidden(true)
    }
}

/// One carousel card: always the real hero render (user skin or the default
/// drawn mock) — only the dial face differs, since a live face is only
/// cached for the currently-connected watch. Peeked (non-active) cards
/// previously got a dimmed, scaled-down generic mock instead, but that
/// flickered in as soon as a card was no longer the active one, including
/// mid-swipe — showing the same real rendering for every card avoids that.
private struct WatchCard: View {
    let known: KnownWatch
    let isActive: Bool
    let face: UIImage?
    let skin: WatchSkinStore

    var body: some View {
        VStack(spacing: 8) {
            WatchHeroImage(face: face, skin: skin)
            if !isActive {
                Text(known.name)
                    .font(Theme.sans(14, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.sub)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isActive ? String(localized: "\(known.name), active watch")
                                     : known.name)
        .accessibilityHint(isActive ? String(localized: "Opens watch management")
                                    : String(localized: "Switches to this watch"))
    }
}

/// Trailing carousel card that starts the add-watch scan flow.
private struct AddWatchCard: View {
    var body: some View {
        VStack(spacing: 10) {
            Circle()
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: 96, height: 96)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Theme.accent)
                )
            Text("Add a watch")
                .font(Theme.sans(14, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(Theme.sub)
        }
        .frame(height: 230)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Add a watch")
        .accessibilityAddTraits(.isButton)
    }
}

/// Management sheet for one watch (opened by tapping the centered carousel
/// card). Everything here is scoped to the selected watch; global preferences
/// live in Settings and are re-applied whenever a compatible watch connects.
@MainActor
struct WatchManageSheet: View {
    private static let debugFileManagerTitle: LocalizedStringResource = "Debug file manager"

    let known: KnownWatch
    @EnvironmentObject var watch: WatchManager
    @EnvironmentObject var registry: WatchRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var showKeyEntry = false
    @State private var confirmingForget = false
    @State private var confirmingReset = false
    @State private var pairing = false

    init(known: KnownWatch) {
        self.known = known
        _name = State(initialValue: known.name)
    }

    private var kind: WatchKind { known.kind ?? .hybridHR }
    private var isActiveReady: Bool {
        known.id == registry.activeWatchID && watch.connectionState == .ready
    }
    private var canManageHardware: Bool { isActiveReady && kind != .misfitQ }
    private var canFactoryReset: Bool {
        canManageHardware && (!kind.needsAuthKey || watch.isAuthenticated)
    }

    var body: some View {
        NavigationStack {
            ThemedScreen(verbatimTitle: known.name) {
                manageSections
            }
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar(id: "watch-detail") {
                ToolbarItem(id: "close", placement: .cancellationAction) {
                    Button("Close") {
                        saveNameIfNeeded()
                        dismiss()
                    }
                }
            }
            .onDisappear(perform: saveNameIfNeeded)
            .sheet(isPresented: $showKeyEntry) {
                KeyEntryView(watchID: known.id)
            }
            .confirmationDialog("Forget \(known.name)?",
                                isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget watch", role: .destructive) {
                    watch.forget(known.id)
                    dismiss()
                }
            } message: {
                Text("Removes the watch, its auth key and its settings from this iPhone. Synced fitness data is kept. The watch itself is not reset.")
            }
            .confirmationDialog("Factory reset \(known.name)?",
                                isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Erase everything on the watch", role: .destructive) { factoryReset() }
            } message: {
                Text("This wipes all data, apps and pairing from the watch and reboots it. You will need to set it up again from scratch.")
            }
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var manageSections: some View {
        nameSection
        watchSection
        appearanceSection
        if kind != .misfitQ { bluetoothSection }
        advancedSection
        connectionSection
    }

    private var nameSection: some View {
        section("Name") {
            HStack(spacing: 13) {
                IconTile(symbol: "pencil")
                TextField("Watch name", text: $name)
                    .font(Theme.sans(16, relativeTo: .body))
                    .foregroundStyle(Theme.ink)
                    .onSubmit(saveNameIfNeeded)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }

    private var watchSection: some View {
        section("Watch", topPadding: 22) {
            if kind.needsAuthKey {
                SettingsRow(icon: "lock", title: "Authenticated") {
                    statusPill(watch.isAuthenticated ? String(localized: "Yes") : String(localized: "No"),
                               positive: watch.isAuthenticated)
                }
                Hairline(leading: 59)
            }
            SettingsRow(icon: "cpu", title: "Firmware") {
                Text(firmwareText).font(Theme.mono(14)).foregroundStyle(Theme.sub)
            }
            if isActiveReady, let battery = watch.batteryLevel {
                Hairline(leading: 59)
                SettingsRow(icon: "battery.75", title: "Battery") {
                    Text("\(battery)%").font(Theme.mono(14)).foregroundStyle(Theme.sub)
                }
            }
            if kind.needsAuthKey {
                Hairline(leading: 59)
                SettingsRow(icon: "key", title: "Auth key", showChevron: true,
                            tap: { showKeyEntry = true })
            }
        }
    }

    private var appearanceSection: some View {
        section("Appearance & calibration", topPadding: 22) {
            manageLink(icon: "paintbrush", title: "Watch appearance") { WatchSkinView() }
            Hairline(leading: 59)
            manageLink(icon: "clock.arrow.circlepath", title: "Calibrate hands",
                       enabled: canManageHardware) { HandCalibrationView() }
        }
    }

    private var bluetoothSection: some View {
        section("Bluetooth", topPadding: 22) {
            SettingsRow(icon: "link", title: "Bluetooth pairing") {
                Text(pairingStatusText).font(Theme.sans(15, relativeTo: .body)).foregroundStyle(Theme.sub)
            }
            if watch.isDevicePaired != true {
                Hairline(leading: 59)
                SettingsRow(icon: "iphone.and.arrow.forward",
                            title: pairingActionTitle,
                            titleColor: Theme.accent,
                            tap: pairingAction)
                    .opacity(canManageHardware && !pairing ? 1 : 0.5)
            }
        }
    }

    private var advancedSection: some View {
        section("Advanced", topPadding: 22) {
#if DEBUG
            manageLink(icon: "folder", title: Self.debugFileManagerTitle,
                       enabled: canManageHardware) { FileManagerView() }
            Hairline(leading: 59)
#endif
            SettingsRow(icon: "arrow.counterclockwise", iconTint: Theme.danger,
                        iconFill: Theme.danger.opacity(0.1), title: "Factory reset",
                        titleColor: Theme.danger, showChevron: true,
                        tap: canFactoryReset ? { confirmingReset = true } : nil)
                .opacity(canFactoryReset ? 1 : 0.5)
        }
    }

    private var connectionSection: some View {
        section("Connection", topPadding: 22) {
            if isActiveReady {
                SettingsRow(icon: "bolt.slash", title: "Disconnect", tap: { watch.disconnect() })
                Hairline(leading: 59)
            }
            SettingsRow(icon: "trash", iconTint: Theme.danger,
                        iconFill: Theme.danger.opacity(0.1), title: "Forget watch",
                        titleColor: Theme.danger, tap: { confirmingForget = true })
        }
    }

    private var firmwareText: String {
        if known.id == registry.activeWatchID, let firmware = watch.firmwareVersion {
            return firmware
        }
        return known.firmware ?? String(localized: "Unknown")
    }

    private var pairingStatusText: String {
        guard known.id == registry.activeWatchID else { return String(localized: "Not connected") }
        switch watch.isDevicePaired {
        case .some(true): return String(localized: "Paired")
        case .some(false): return String(localized: "Not paired")
        case .none: return String(localized: "Unknown")
        }
    }

    private var pairingActionTitle: LocalizedStringResource {
        pairing ? "Waiting for iOS dialog…" : "Pair with iPhone"
    }

    private var pairingAction: (() -> Void)? {
        guard canManageHardware, !pairing else { return nil }
        return { pair() }
    }

    private func statusPill(_ text: String, positive: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(positive ? Theme.success : Theme.warn).frame(width: 7, height: 7)
            Text(text)
                .font(Theme.sans(15, weight: .semibold, relativeTo: .body))
                .foregroundStyle(positive ? Theme.success : Theme.warn)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringResource, topPadding: CGFloat = 0,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title).padding(.top, topPadding)
            ThemedCard(content: content)
        }
    }

    private func manageLink<Destination: View>(icon: String, title: LocalizedStringResource,
                                                enabled: Bool = true,
                                                @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink { destination() } label: {
            SettingsRow(icon: icon, title: title, showChevron: true)
        }
        .buttonStyle(PressableRow())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
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

    private func factoryReset() {
        Task {
            do {
                try await watch.factoryReset()
                await MainActor.run {
                    ToastCenter.shared.success(
                        String(localized: "Factory reset sent — watch is rebooting"))
                    watch.forget(known.id)
                    dismiss()
                }
            } catch {
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }

    private func saveNameIfNeeded() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != known.name else { return }
        registry.rename(known.id, to: trimmed)
    }
}

// MARK: - Hero watch render + pedestal

/// The watch presented as a product hero: the app's live SwiftUI watch render
/// (user skin or a drawn mock, with the downloaded e-ink face on the dial)
/// floating on a soft elliptical pedestal shadow. `skin` is passed in rather
/// than always reading `WatchSkinStore.shared` — the carousel's peeked cards
/// pass a store pinned to that specific (non-active) watch, so each card
/// shows its own skin instead of whichever watch `shared` currently tracks.
struct WatchHeroImage: View {
    let face: UIImage?
    @ObservedObject var skin: WatchSkinStore

    var body: some View {
        ZStack {
            // Pedestal: soft radial ellipse under the watch.
            Ellipse()
                .fill(RadialGradient(
                    gradient: Gradient(colors: [.black.opacity(0.16), .black.opacity(0)]),
                    center: .center, startRadius: 0, endRadius: 75))
                .frame(width: 150, height: 26)
                .offset(y: 90)

            Group {
                if skin.hasCase {
                    SkinnedWatchView(skin: skin, face: face)
                } else {
                    DrawnWatchMock(face: face)
                }
            }
            .frame(height: 228)
            .themeShadow(Theme.heroShadow)
        }
        .frame(width: 200, height: 230)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Watch preview")
    }
}

/// Composites the user-supplied case + hand images with the live e-ink face,
/// rotating the hands to the current time (see WatchCompositeView).
private struct SkinnedWatchView: View {
    @ObservedObject var skin: WatchSkinStore
    let face: UIImage?

    var body: some View {
        // Re-render on the minute boundary so the hands track the time.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let time = watchHandAngles(at: context.date)
            WatchCompositeView(skin: skin, face: face,
                               hourAngle: time.hour, minuteAngle: time.minute)
        }
    }
}

private func watchHandAngles(at date: Date) -> (hour: Double, minute: Double) {
    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
    let h = Double(c.hour ?? 0), m = Double(c.minute ?? 0)
    return (hour: (h.truncatingRemainder(dividingBy: 12) + m / 60) * 30,
            minute: m * 6)
}

/// Bundled watch artwork with the live face composited into its dial — used
/// when the user hasn't supplied a case skin (Settings → Watch appearance).
struct DrawnWatchMock: View {
    let face: UIImage?
    private let artAspect: CGFloat = 1500.0 / 2102.0
    private let dialDiameterFraction: CGFloat = 0.5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let time = watchHandAngles(at: context.date)
            watch(hourAngle: time.hour, minuteAngle: time.minute)
        }
    }

    private func watch(hourAngle: Double, minuteAngle: Double) -> some View {
        GeometryReader { geo in
            let artWidth = min(geo.size.width, geo.size.height * artAspect)
            let artHeight = artWidth / artAspect
            let dialSize = artWidth * dialDiameterFraction

            ZStack {
                Image("DefaultWatchMock")
                    .resizable()
                    .scaledToFit()

                if let face {
                    Image(uiImage: face)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: dialSize, height: dialSize)
                        .clipShape(Circle())
                }

                Image("DefaultWatchHourHand")
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(hourAngle))

                Image("DefaultWatchMinuteHand")
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(minuteAngle))
            }
            .frame(width: artWidth, height: artHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 200, height: 228)
    }
}
