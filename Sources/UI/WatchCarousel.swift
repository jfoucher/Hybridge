@preconcurrency import SwiftUI
@preconcurrency import UIKit

/// Item identity for the dashboard's horizontal watch carousel: one card per
/// known watch (first-added → last, `WatchRegistry.watches` order), plus a
/// trailing "add watch" card.
enum CarouselItem: Hashable {
    case watch(UUID)
    case add
}

private enum CardLayout {
    /// Minimum height of the name band. Every card's name is one line, so
    /// reserving it keeps the heroes on the same line across cards; the band
    /// still grows past it when Dynamic Type makes the name taller.
    static let nameBand: CGFloat = 50
    static let hero: CGFloat = 230
    /// First-frame guess only — the real height is measured (`CardHeightKey`).
    static let estimate: CGFloat = nameBand + hero + 111
}

/// Height of the tallest card. The cards are laid out at that height so the
/// page below never shifts while swiping, and so each band (name, hero,
/// caption, pills) stays on the same line across neighbouring cards mid-drag.
///
/// Measured rather than hard-coded: every band below the hero is text, so its
/// real height depends on the locale, the font and the user's Dynamic Type
/// setting. A hard-coded box either clipped what overflowed it (the scroll
/// view clips) or left a lot of dead space at accessibility text sizes.
private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// Reports this view's natural height as the card-height preference.
    func measuringCardHeight() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: CardHeightKey.self, value: geo.size.height)
        })
    }
}

/// Swipeable hero replacing the old header Menu switcher (audit finding M6):
/// watches ordered first-added → last, both neighbors partially visible so
/// the swipe is discoverable, and a full swipe activates the next watch via
/// `WatchManager.switchTo`. Tapping the centered card opens the management
/// sheet (rename / auth key / disconnect / forget); tapping a peeked
/// neighbor scrolls it to center instead of switching immediately. The
/// trailing "+" card starts the existing add-watch scan flow.
///
/// Each card carries its watch's *own* name, face name, family, connection
/// pill, battery, Locate button and last-sync line — read from that watch's
/// `WatchConnection` rather than the `WatchManager` facade, which only ever
/// mirrors the active watch. They live inside the scroll content so they
/// travel with the swipe instead of snapping over once the switch commits
/// (~350 ms after the drag settles).
///
/// `scrolledItem` is owned by the parent (`DashboardView`) rather than kept
/// internal: the dashboard needs to know when the carousel is parked on the
/// "Add a watch" card so it can hide the transfer progress, which describes
/// the previous *watch*, not the add flow.
struct WatchCarousel: View {
    @EnvironmentObject var watch: WatchManager
    @EnvironmentObject var registry: WatchRegistry
    @StateObject private var fitness = FitnessStore.shared
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

    private let peekInset: CGFloat = 34
    private let cardSpacing: CGFloat = 14
    /// The tallest card, measured from the cards themselves; the initial
    /// value only has to carry the very first frame.
    @State private var cardHeight: CGFloat = CardLayout.estimate

    var body: some View {
        VStack(spacing: 10) {
            // One card per page: the width the cards are given is the scroll
            // view's own width less the two content margins, which is exactly
            // what `containerRelativeFrame(.horizontal)` used to resolve to —
            // measured instead, because that modifier keeps the width it first
            // resolved across a device rotation (see ContainerWidthReader).
            ContainerWidthReader { width in
                let cardWidth = max(0, width - peekInset * 2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: cardSpacing) {
                        ForEach(registry.watches) { known in
                            let isActive = known.id == registry.activeWatchID
                            WatchCard(known: known,
                                      isActive: isActive,
                                      face: watch.watchfacePreviewImage(for: known.id),
                                      skin: isActive ? WatchSkinStore.shared : pinnedSkinStore(for: known.id),
                                      connection: watch.fleet.ensureConnection(for: known.id),
                                      lastSync: fitness.lastSync(for: known.id))
                                .frame(width: cardWidth, height: cardHeight, alignment: .top)
                                .id(CarouselItem.watch(known.id))
                                .onTapGesture { handleTap(on: known) }
                        }
                        AddWatchCard()
                            .frame(width: cardWidth, height: cardHeight, alignment: .top)
                            .id(CarouselItem.add)
                            .onTapGesture { showAddSheet = true }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $scrolledItem)
                .contentMargins(.horizontal, peekInset, for: .scrollContent)
            }
            .frame(height: cardHeight)
            .onPreferenceChange(CardHeightKey.self) { height in
                guard height > 0 else { return }
                Task { @MainActor in cardHeight = height }
            }

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

/// One carousel card: the watch's name, the real hero render (user skin or
/// the default drawn mock) with that watch's own dial face — the live
/// downloaded face for the connected watch, the bundled artwork for every
/// other card (see `WatchManager.watchfacePreviewImage(for:)`, which keys the
/// face to the watch id so a switch never flashes the previous watch's face)
/// — and that watch's glance: face name, family, connection, battery, Locate
/// and last sync. Peeked (non-active) cards previously got a dimmed,
/// scaled-down generic mock instead, but that flickered in as soon as a card
/// was no longer the active one, including mid-swipe — showing the same real
/// rendering for every card avoids that.
///
/// Everything is read from this card's own `WatchConnection`, so a peeked
/// card shows *its* watch's live state (the fleet keeps every roster watch
/// connected) rather than the active watch's. Interactive bits are inert
/// while the card isn't active: a tap anywhere on a peeked card scrolls it to
/// centre, which is also what makes the actions unambiguous — they always
/// belong to the watch you're looking at.
private struct WatchCard: View {
    let known: KnownWatch
    let isActive: Bool
    let face: UIImage?
    let skin: WatchSkinStore
    @ObservedObject var connection: WatchConnection
    let lastSync: Date?

    @EnvironmentObject var registry: WatchRegistry
    @State private var editingName = false
    @State private var nameDraft = ""
    @State private var findingWatch = false
    @State private var pairing = false

    private var kind: WatchKind { known.kind ?? .hybridHR }
    private var isReady: Bool { connection.connectionState == .ready }

    var body: some View {
        VStack(spacing: 0) {
            nameBand
            WatchHeroImage(face: face, skin: skin)
            faceNameLine
            Text("Fossil \(kind.displayName)")
                .font(Theme.sans(15, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(Theme.sub)
                .padding(.top, 4)
            statusGlance.padding(.top, 14)
        }
        // Natural height, so the carousel can size every card to the tallest.
        .measuringCardHeight()
        // A peeked card is a preview: its buttons and the rename field would
        // otherwise act on a watch that isn't active yet, and would swallow
        // the tap that scrolls the card to centre.
        .allowsHitTesting(isActive)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isActive ? String(localized: "\(known.name), active watch")
                                     : known.name)
        .accessibilityHint(isActive ? String(localized: "Opens watch management")
                                    : String(localized: "Switches to this watch"))
    }

    // MARK: Name

    private var nameBand: some View {
        Group {
            if editingName {
                TextField("Name", text: $nameDraft, onCommit: commitNameEdit)
                    .font(Theme.serif(32))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
            } else {
                Text(known.name)
                    .font(Theme.serif(40))
                    .tracking(0.3)
                    // One line, shrinking to fit, so a long name can't make
                    // one card taller than its neighbours.
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(Theme.ink)
                    .onTapGesture(perform: beginNameEdit)
            }
        }
        .frame(maxWidth: .infinity)
        // A floor, not a cap: at large text sizes the name is taller than the
        // band and must be allowed to grow rather than be clipped.
        .frame(minHeight: CardLayout.nameBand)
    }

    private func beginNameEdit() {
        nameDraft = known.name
        editingName = true
    }

    private func commitNameEdit() {
        defer { editingName = false }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != known.name else { return }
        registry.rename(known.id, to: trimmed)
    }

    // MARK: Caption

    /// Face name — HR only; hands-only Q hybrids have none. Rendered
    /// transparent rather than removed so the caption and pills below sit on
    /// the same line on every card.
    private var faceNameLine: some View {
        Text(kind.hasWatchfaces ? (connection.activeWatchfaceName?.uppercased() ?? "") : "")
            .font(Theme.mono(12, weight: .medium))
            .tracking(0.6)
            .lineLimit(1)
            .foregroundStyle(Theme.accent)
            .padding(.top, 2)
    }

    // MARK: Status glance

    private var statusGlance: some View {
        // "Synced 5 min ago" ages without anything publishing — tick so the
        // relative phrasing keeps up on its own.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 8) {
                // One row, always: the labels shrink to fit (see `pillLabel`)
                // rather than wrapping onto a second line, which would make
                // the glance a different height per card and per connection
                // state. Three pills need ~336pt at full size, more than a
                // card is wide on a small phone or in a long locale.
                HStack(spacing: 8) {
                    connectionPill
                    if let battery = connection.batteryLevel { batteryPill(battery) }
                    if isReady { findButton }
                }
                // Free to wrap: it's the last line of the card, the card is
                // sized to whatever it needs, and truncating a "Synced …"
                // to an ellipsis would be worse than a second line.
                Text(syncLine)
                    .font(Theme.sans(12, relativeTo: .caption))
                    .foregroundStyle(Theme.sub)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectionPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connState.dot)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(connState.halo, lineWidth: 3).scaleEffect(1.75))
            pillLabel(connState.label)
                .tracking(0.1)
                .foregroundStyle(Theme.ink)
        }
        .pill()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connState.label)
        .onTapGesture { pairingAction?() }
    }

    private func batteryPill(_ level: Int) -> some View {
        HStack(spacing: 6) {
            BatteryGlyph(level: level, fill: batteryColor(level))
            Text("\(level, format: .percent)")
                .font(Theme.mono(13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Theme.ink)
        }
        .pill()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(level, format: .percent)")
    }

    /// Pill text that gives way before the row does: one line, shrinking to
    /// 75% so three pills always fit side by side.
    private func pillLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.sans(13, weight: .semibold, relativeTo: .footnote))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func batteryColor(_ level: Int) -> Color {
        if level <= 15 { return Theme.danger }
        if level <= 30 { return Theme.warn }
        return Theme.ink
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
                pillLabel(findingWatch ? String(localized: "Vibrating…")
                                       : String(localized: "Locate"))
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .pill()
        .disabled(findingWatch)
        .accessibilityLabel("Find watch")
        .accessibilityHint("Vibrates the watch so you can locate it")
    }

    /// Connection state collapsed to the visual states in the design. An
    /// out-of-range watch reads as "Disconnected" rather than "Connecting…"
    /// forever — `WatchConnection` decays a stuck `.connecting` while keeping
    /// the pending connect armed.
    private var connState: (dot: Color, halo: Color, label: String) {
        switch connection.connectionState {
        case .ready:
            if connection.isDevicePaired ?? false {
                return (Theme.success, Theme.success.opacity(0.16), String(localized: "Connected"))
            }
            return (Theme.warn, Theme.warn.opacity(0.16), String(localized: "Unpaired"))
        case .bluetoothOff:
            return (Theme.warn, Theme.warn.opacity(0.16), String(localized: "Bluetooth off"))
        case .connecting, .initializing, .authenticating, .scanning:
            return (Theme.warn, Theme.warn.opacity(0.16), connection.connectionState.label)
        case .disconnected, .failed:
            return (Theme.danger, Theme.danger.opacity(0.16), String(localized: "Disconnected"))
        }
    }

    private var syncLine: String {
        guard connection.connectionState != .bluetoothOff else {
            return String(localized: "Turn on Bluetooth to reconnect")
        }
        guard let lastSync else {
            return String(localized: "Not synced yet")
        }
        // Within a minute of syncing, say "now" rather than let
        // RelativeDateTimeFormatter phrase a sub-second interval as the future
        // ("in 0 seconds") — it rounds the difference to zero and defaults to
        // future phrasing.
        if lastSync.timeIntervalSinceNow > -60 {
            return String(localized: "Synced now")
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return String(localized: "Synced \(f.localizedString(for: lastSync, relativeTo: Date()))")
    }

    // MARK: Actions (always this card's watch, never the facade's target)

    private var canManageHardware: Bool { isReady && kind != .misfitQ }

    private var pairingAction: (() -> Void)? {
        guard canManageHardware, !pairing, !(connection.isDevicePaired ?? false) else { return nil }
        return { pair() }
    }

    private func findWatch() {
        findingWatch = true
        Task {
            do {
                if let confirmed = try await connection.findActiveWatchAndConfirm() {
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
                try await connection.performDevicePairing()
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
}

/// Trailing carousel card that starts the add-watch scan flow. Its artwork
/// occupies the name + hero bands so the "+" lands where the watches do,
/// with the glance area below left empty.
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
        .frame(maxWidth: .infinity)
        // Centred in the hero band (not the whole card), so the "+" lands
        // where the watches are rather than drifting up into the name band.
        .frame(height: CardLayout.hero)
        .padding(.top, CardLayout.nameBand)
        .measuringCardHeight()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Add a watch")
        .accessibilityAddTraits(.isButton)
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
    @State private var rescueArmed = WatchfaceRescue.isArmed
    @State private var choosingRescue = false
    @State private var pickingRescueTarget = false
    @State private var confirmingRescueReset = false
    @State private var importingRescueFirmware = false

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
            .confirmationDialog("Rescue a rebooting watch", isPresented: $choosingRescue,
                                titleVisibility: .visible) {
                rescueModeDialog
            } message: {
                Text("The watch is only reachable for a few seconds per reboot, so the chosen step runs from the connection itself rather than now.")
            }
            .confirmationDialog("Which face is the bad one?", isPresented: $pickingRescueTarget,
                                titleVisibility: .visible) {
                ForEach(watch.installedApps.filter(\.isWatchface)) { face in
                    Button(face.name) { armRescue(.overwriteFace, target: face.name) }
                }
            } message: {
                Text("A working face is downloaded from the watch and reinstalled under this name, which forces the watch to clear the broken one.")
            }
            .confirmationDialog("Factory reset on next connection?",
                                isPresented: $confirmingRescueReset, titleVisibility: .visible) {
                Button("Erase everything on the watch", role: .destructive) {
                    armRescue(.factoryReset)
                }
            } message: {
                Text("This wipes the watch, including its pairing and auth key. The watch refuses it unless the stored auth key is the right one.")
            }
            .fileImporter(isPresented: $importingRescueFirmware,
                          allowedContentTypes: [.data]) { result in
                stageRescueFirmware(result)
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
        if kind.hasWatchfaces { rescueSection }
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
                    Text("\(battery, format: .percent)").font(Theme.mono(14)).foregroundStyle(Theme.sub)
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

    // MARK: Rescue

    /// Recovery for a watch a bad watchface has put in a reboot loop. It has to
    /// arm rather than act: such a watch is only reachable for a few seconds
    /// per cycle, so the work runs from the connection itself, not from a tap.
    private var rescueSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Rescue").padding(.top, 22)
            ThemedCard {
                SettingsRow(icon: rescueArmed ? "xmark.octagon" : "cross.case",
                            iconTint: Theme.danger, iconFill: Theme.danger.opacity(0.1),
                            title: rescueArmed ? "Cancel rescue" : "Rescue a rebooting watch",
                            titleColor: Theme.danger,
                            showChevron: !rescueArmed) {
                    if rescueArmed {
                        WatchfaceRescue.disarm()
                        rescueArmed = false
                        ToastCenter.shared.success(String(localized: "Rescue disarmed"))
                    } else {
                        choosingRescue = true
                    }
                }
                if rescueArmed {
                    Hairline(leading: 59)
                    Text(armedRescueSummary)
                        .font(Theme.sans(14, relativeTo: .footnote))
                        .foregroundStyle(Theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            rescueExplanation
        }
    }

    /// Deliberately describes the mechanism, not a reassuring summary of it:
    /// the step looks like a failed upload while it is working, and someone
    /// reading the log needs to know that is the expected shape of success.
    private var rescueExplanation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A watchface that crashes the firmware makes the watch reboot every minute or so, leaving only a few seconds per cycle to talk to it. A watch in that state answers reads — listing apps, downloading files — but **ignores every request to delete a file**, and hangs on anything the watchface engine itself has to handle, so neither removing the bad face nor switching away from it is possible.")
            Text("**Replace a face** works around that. It downloads a stock face off the watch, re-labels it with the broken face's name and installs it. To install a face under a name that already exists, the watch's app manager has to clear the old one first — the delete it refuses to do for us, it will do for itself. The upload usually never gets acknowledged: the watch rebuilds its app storage and drops the link part-way. That is the fix working, not failing. At the next connection the bad face is gone, the watch can't find the face it was told to display, and it falls back to a stock one.")
            Text("Expect to lose watchfaces you installed yourself — the rebuild tends to take all of them. Nothing in this step needs the auth key. It re-runs on every connection until a listing proves the face is gone, so keep the app open and the watch nearby.")
            Text("The other options are for when that isn't the problem: **delete faces** only works on a watch that isn't crash-looping, and **factory reset** and **reflash firmware** are refused by the watch unless the stored auth key is the right one.")
        }
        .font(Theme.sans(13, relativeTo: .footnote))
        .foregroundStyle(Theme.sub)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4).padding(.top, 12)
    }

    /// What the armed rescue will do on the next connection.
    private var armedRescueSummary: String {
        switch WatchfaceRescue.mode {
        case .overwriteFace:
            String(localized: "Armed: reinstall \(WatchfaceRescue.targetFace ?? "a face") with working code")
        case .deleteFaces:
            String(localized: "Armed: delete every face but one")
        case .factoryReset:
            String(localized: "Armed: factory reset")
        case .reflashFirmware:
            String(localized: "Armed: reflash firmware")
        }
    }

    /// Separate choices rather than an automatic escalation: only the user
    /// knows which face is the bad one, and the last two can't be undone.
    @ViewBuilder
    private var rescueModeDialog: some View {
        Button("Replace a face…") { pickingRescueTarget = true }
        Button("Delete every face but one") { armRescue(.deleteFaces) }
        Button("Factory reset", role: .destructive) { confirmingRescueReset = true }
        Button("Reflash firmware…") { importingRescueFirmware = true }
    }

    private func armRescue(_ mode: WatchfaceRescueMode, target: String? = nil) {
        WatchfaceRescue.mode = mode
        WatchfaceRescue.targetFace = target
        WatchfaceRescue.isArmed = true
        rescueArmed = true
        ToastCenter.shared.success(String(
            localized: "Rescue armed — keep the app open and near the watch"))
        // If the watch happens to be reachable now, don't wait for a reconnect.
        Task {
            await watch.runWatchfaceRescue()
            await MainActor.run { rescueArmed = WatchfaceRescue.isArmed }
        }
    }

    /// Stages the DFU image outside the security-scoped URL, which is gone by
    /// the time the watch next connects.
    private func stageRescueFirmware(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              FirmwareReader.isFirmware(data) else {
            ToastCenter.shared.error(String(localized: "That isn't a Hybrid HR firmware image"))
            return
        }
        guard let directory = WatchfaceRescue.firmwareDirectory else { return }
        let staged = directory.appendingPathComponent("rescue-firmware.bin")
        do {
            try? FileManager.default.removeItem(at: staged)
            try data.write(to: staged, options: .atomic)
        } catch {
            ToastCenter.shared.error(String(localized: "Could not stage the firmware image"))
            return
        }
        WatchfaceRescue.firmwareURL = staged
        armRescue(.reflashFirmware)
    }

    /// Live keep-connected preference (the `known` snapshot can be stale after
    /// a toggle, so read it from the registry).
    private var keepConnected: Bool {
        (registry.watches.first { $0.id == known.id }?.keepConnected) != false
    }

    private var connectionSection: some View {
        section("Connection", topPadding: 22) {
            SettingsRow(icon: "antenna.radiowaves.left.and.right", title: "Keep connected") {
                Toggle(isOn: Binding(
                    get: { keepConnected },
                    set: { watch.setKeepConnected($0, for: known.id) }
                )) { EmptyView() }
                    .labelsHidden().brassToggle()
            }
            Hairline(leading: 59)
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
