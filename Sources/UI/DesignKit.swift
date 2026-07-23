import SwiftUI
import UIKit

// Shared building blocks for the "Warm brass" redesign (handoff direction 1a).
// Every tab screen composes these so the identity stays consistent and the
// tokens live in exactly one place (Theme).

// MARK: - Screen scaffold

/// Standard themed screen: warm background, a scrolling column with the big
/// serif title (and an optional trailing circular action button), bottom
/// padding. Content is inset 22pt and capped to a readable width on iPad.
struct ThemedScreen<Content: View>: View {
    private let title: String
    var action: (symbol: String, run: () -> Void)?
    @ViewBuilder var content: () -> Content
    @Environment(\.floatingTabBarHeight) private var tabBarHeight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: LocalizedStringResource,
         action: (symbol: String, run: () -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = String(localized: title)
        self.action = action
        self.content = content
    }

    init(verbatimTitle title: String,
         action: (symbol: String, run: () -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.action = action
        self.content = content
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center) {
                        Text(title)
                            .font(dynamicTypeSize.isAccessibilitySize
                                  ? Theme.serif(25, relativeTo: .title3)
                                  : Theme.serif(40))
                            .tracking(0.3)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let action {
                            CircleActionButton(symbol: action.symbol, run: action.run)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 12)

                    content()
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 32 + tabBarHeight)
                .frame(maxWidth: 760)
                // Pins the column to the scroll view's own width instead of
                // merely centering it. `frame(maxWidth: .infinity)` grows to
                // fit an oversized child, and a content column even a fraction
                // of a point wider than the viewport turns this vertical
                // ScrollView into a freely two-dimensional one — the whole
                // screen then drags sideways from anywhere. Sub-pixel rounding
                // inside a card is enough to trip it.
                .containerRelativeFrame(.horizontal)
            }
        }
    }
}

/// 44pt circular action button (brass glyph) shown top-right on Faces & Alarms.
struct CircleActionButton: View {
    let symbol: String
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.card))
                .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                .themeShadow(Theme.ShadowStyle(color: .black.opacity(0.04), radius: 1, y: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section label + card + footer

/// Small uppercase group label above a card.
struct SectionLabel: View {
    let text: String
    init(_ text: LocalizedStringResource) { self.text = String(localized: text) }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.sans(12, weight: .semibold, relativeTo: .caption))
            .tracking(0.6)
            .foregroundStyle(Theme.sub)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rounded surface card (radius 22) used to group rows.
struct ThemedCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .themeShadow(Theme.ShadowStyle(color: .black.opacity(0.04), radius: 9, y: 4))
    }
}

/// Teaching-tone explanatory copy under a card. This density is a defining
/// trait of the app — keep it.
struct Footer: View {
    let text: String
    init(_ text: LocalizedStringResource) { self.text = String(localized: text) }

    var body: some View {
        Text(text)
            .font(Theme.sans(12, relativeTo: .caption))
            .foregroundStyle(Theme.sub)
            .lineSpacing(2)
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 1px divider between rows, inset to clear a leading icon/thumbnail.
struct Hairline: View {
    var leading: CGFloat = 16
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, leading)
    }
}

// MARK: - Icon tile + chevron

/// 30pt rounded-square icon tile leading a settings row.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var fill: Color = Theme.softFill

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.chevron)
    }
}

// MARK: - Settings row

/// A grouped-card row: leading icon tile, title, optional trailing content,
/// optional chevron. `tap` makes the whole row a button.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    var iconTint: Color = Theme.accent
    var iconFill: Color = Theme.softFill
    let title: String
    var titleColor: Color = Theme.ink
    var showChevron = false
    var tap: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(icon: String, iconTint: Color = Theme.accent, iconFill: Color = Theme.softFill,
         title: LocalizedStringResource, titleColor: Color = Theme.ink,
         showChevron: Bool = false, tap: (() -> Void)? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = icon
        self.iconTint = iconTint
        self.iconFill = iconFill
        self.title = String(localized: title)
        self.titleColor = titleColor
        self.showChevron = showChevron
        self.tap = tap
        self.trailing = trailing
    }

    var body: some View {
        let row = Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 13) {
                        IconTile(symbol: icon, tint: iconTint, fill: iconFill)
                        titleText
                        Spacer(minLength: 8)
                        if showChevron { Chevron().padding(.top, 8) }
                    }
                    trailing()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 43)
                }
            } else {
                HStack(spacing: 13) {
                    IconTile(symbol: icon, tint: iconTint, fill: iconFill)
                    titleText
                    Spacer(minLength: 8)
                    trailing()
                    if showChevron { Chevron() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())

        if let tap {
            Button(action: tap) { row }.buttonStyle(PressableRow())
        } else {
            row
        }
    }

    private var titleText: some View {
        Text(title)
            .font(Theme.sans(16, relativeTo: .body))
            .foregroundStyle(titleColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(icon: String, iconTint: Color = Theme.accent, iconFill: Color = Theme.softFill,
         title: LocalizedStringResource, titleColor: Color = Theme.ink,
         showChevron: Bool = false, tap: (() -> Void)? = nil) {
        self.init(icon: icon, iconTint: iconTint, iconFill: iconFill, title: title,
                  titleColor: titleColor, showChevron: showChevron, tap: tap,
                  trailing: { EmptyView() })
    }
}

/// Subtle press feedback for tappable rows (standard iOS touch feel).
struct PressableRow: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.line.opacity(0.4) : .clear)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

// MARK: - Brass toggle

/// 50×30 pill toggle: ON = success (knob right), OFF = warm grey (knob left).
struct BrassToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.success : Theme.toggleOff)
                    .frame(width: 50, height: 30)
                Circle()
                    .fill(.white)
                    .frame(width: 25, height: 25)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                    .padding(2.5)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? String(localized: "On")
                                               : String(localized: "Off"))
    }
}

extension View {
    /// Applies the brass toggle look to any `Toggle`.
    func brassToggle() -> some View { toggleStyle(BrassToggle()) }

    /// Warm background for the stock `Form`/`List` detail sub-screens: hides
    /// SwiftUI's default grouped background (which the global UIKit appearance
    /// can't override) and paints the page in `Theme.bg`. Rows keep their
    /// near-white cells, reading as cards on the warm page.
    ///
    /// Also reserves bottom scroll-content space for the floating tab bar: a
    /// `NavigationStack` doesn't forward the bar's `safeAreaInset` to its pushed
    /// scrolling screens, so — just like `ThemedScreen` — these `List`/`Form`
    /// sub-screens must add the measured bar height themselves, or their last
    /// rows scroll under the bar (`floatingTabBarHeight` is 0 in the sidebar).
    func themedList() -> some View {
        modifier(ThemedListModifier())
    }
}

private struct ThemedListModifier: ViewModifier {
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .tint(Theme.accent)
            .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
    }
}

// MARK: - Segmented control

/// Themed segmented control (track #F0ECE2, selected = raised white card).
struct ThemedSegmented<T: Hashable>: View {
    let options: [(value: T, label: LocalizedStringResource)]
    @Binding var selection: T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 2) {
                    ForEach(options, id: \.value) { optionButton($0) }
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(options, id: \.value) { optionButton($0) }
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.softFill))
    }

    private func optionButton(_ option: (value: T, label: LocalizedStringResource)) -> some View {
        let active = option.value == selection
        return Button {
            selection = option.value
        } label: {
            Text(String(localized: option.label))
                .font(Theme.sans(14, weight: active ? .semibold : .regular,
                                 relativeTo: .footnote))
                .foregroundStyle(active ? Theme.ink : Theme.sub)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
                .frame(maxWidth: .infinity,
                       alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 10 : 7)
                .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 12 : 2)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(active ? Theme.card : .clear)
                        .themeShadow(active
                                     ? Theme.ShadowStyle(color: .black.opacity(0.08), radius: 1, y: 1)
                                     : Theme.ShadowStyle(color: .clear, radius: 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityLabel(Text(option.label))
    }
}

// MARK: - Stepper pill

/// Inline −/value/+ pill (brass glyphs, mono value) used for the step goal.
struct StepperPill: View {
    let text: String
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("minus", label: "Decrease", action: onMinus)
            Text(text)
                .font(Theme.mono(15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 56)
                .padding(.horizontal, 2)
                .accessibilityHidden(true)
            button("plus", label: "Increase", action: onPlus)
        }
        .background(Capsule().fill(Theme.softFill))
        .accessibilityElement(children: .ignore)
        .accessibilityValue(text)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onPlus()
            case .decrement: onMinus()
            default: break
            }
        }
    }

    private func button(_ symbol: String, label: LocalizedStringResource,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Day chips

/// Row of 7 circular day chips (Mon→Sun), active filled brass.
struct DayChips: View {
    /// Watch bit order: Sun=0 Mon=1 Tue=2 Thu=3 Wed=4 Fri=5 Sat=6.
    let daysMask: UInt8
    private let order = [1, 2, 4, 3, 5, 6, 0]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(order, id: \.self) { bit in
                let on = daysMask & (1 << bit) != 0
                Text(Self.shortName(for: bit))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? .white : Theme.dayChipOffText)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(on ? Theme.accent : Theme.dayChipOff))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activeDaysSummary)
    }

    private var activeDaysSummary: String {
        let active = order.filter { daysMask & (1 << $0) != 0 }
            .map(Self.fullName(for:))
        if active.isEmpty { return String(localized: "No days selected") }
        if active.count == 7 { return String(localized: "Every day") }
        return ListFormatter.localizedString(byJoining: active)
    }

    /// Foundation's weekday arrays are Sunday-first, matching the watch's
    /// weekday bit values except for its verified Wednesday/Thursday swap.
    private static func calendarIndex(for bit: Int) -> Int {
        switch bit {
        case 3: return 4
        case 4: return 3
        default: return bit
        }
    }

    private static func shortName(for bit: Int) -> String {
        DateFormatter().veryShortWeekdaySymbols[calendarIndex(for: bit)]
    }

    private static func fullName(for bit: Int) -> String {
        DateFormatter().weekdaySymbols[calendarIndex(for: bit)]
    }
}

// MARK: - Stat tile (icon + number + label)

/// One activity tile (brass SF Symbol, mono number, sub label). Shared by the
/// Fitness "Today" card; the Dashboard keeps its own ring-integrated variant.
struct StatTile: View {
    let symbol: String
    let value: String
    let label: LocalizedStringResource

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(Theme.mono(20, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(String(localized: label))
                .font(Theme.sans(12, weight: .medium, relativeTo: .caption))
                .foregroundStyle(Theme.sub)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Thin vertical hairline used between tiles in a stat card.
struct TileDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(width: 1).padding(.vertical, 4)
    }
}

// MARK: - Swipe to delete

/// Swipe-to-delete for the custom `ThemedCard` rows that don't live inside a
/// `List` (so `.swipeActions` isn't available). Drag the row left to reveal a
/// red Delete button; release past the far threshold to delete immediately, or
/// tap the button. Mirrors the native list gesture on the app's cards.
///
/// Rows that pass `onShare` also get a *leading* action: drag right to uncover
/// the share glyph and it fires on release. That edge deliberately never parks
/// open with a button to tap — sharing is meant to be one gesture, not a swipe
/// followed by a tap — so the row always springs back to rest. Its travel is
/// capped at `buttonWidth` with heavy resistance past that: a full-width row
/// that slides further than its own action reads as the whole screen moving.
///
/// `cornerRadius` should match the wrapped surface (22 for a standalone
/// `ThemedCard`, 0 for a row inside a shared card that already clips). Pass the
/// card's `shadow` so the raised look survives the clip this applies.
struct SwipeToDelete<Content: View>: View {
    var cornerRadius: CGFloat = 0
    var shadow: Theme.ShadowStyle?
    let onDelete: () -> Void
    /// Optional leading-edge action. Nil keeps the original behaviour, where a
    /// rightward pull only rubber-bands.
    var onShare: (() -> Void)?
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var resting: CGFloat = 0
    // True while the swipe pan is active. Disables the row's own buttons
    // mid-touch so a released drag is never misread as a tap on the row (or
    // on a button inside it).
    @State private var isDragging = false

    private let buttonWidth: CGFloat = 82

    var body: some View {
        // Distance the row must travel for a release to delete outright.
        let fullSwipe = buttonWidth * 2.6
        // Reached just before the row stops tracking the finger, so the swipe
        // fires exactly when the share glyph is fully uncovered.
        let shareThreshold = buttonWidth * 0.85
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.danger)
                .overlay(alignment: .trailing) {
                    Button(action: onDelete) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: buttonWidth)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .opacity(offset < -1 ? 1 : 0)

            if onShare != nil {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.accent)
                    .overlay(alignment: .leading) {
                        // An affordance, not a control: the row never rests
                        // open on this edge, so there is nothing to tap.
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: buttonWidth)
                            .frame(maxHeight: .infinity)
                    }
                    .opacity(offset > 1 ? 1 : 0)
            }

            content()
                // The swipe is driven by a UIKit pan recognizer (not a SwiftUI
                // DragGesture): a SwiftUI drag that wins the touch — which
                // happens whenever the first ~14pt of movement lean sideways —
                // knocks the enclosing ScrollView's pan out for the rest of
                // that touch, so a diagonal-start scroll went dead. The UIKit
                // recognizer opts into *simultaneous* recognition with the
                // scroll pan, so the list keeps scrolling vertically even
                // while a row is being swiped.
                .overlay {
                    SwipePanCatcher(
                        onBegan: { isDragging = true },
                        onChanged: { tx in
                            let raw = resting + tx
                            // Left reveals the delete button; right tracks the
                            // finger only when there's a leading action to
                            // trigger, and otherwise just rubber-bands.
                            if raw < 0 {
                                offset = max(raw, -fullSwipe)
                            } else if onShare == nil {
                                offset = raw * 0.2
                            } else {
                                // Tracks the finger just far enough to uncover
                                // the share glyph, then resists hard. Letting
                                // it run to `fullSwipe` made a full-width row
                                // slide half the screen, which reads as the
                                // whole view being draggable rather than as a
                                // row action.
                                offset = raw <= buttonWidth
                                    ? raw
                                    : buttonWidth + (raw - buttonWidth) * 0.15
                            }
                        },
                        onEnded: { tx, cancelled in
                            isDragging = false
                            let raw = resting + tx
                            if !cancelled && raw <= -fullSwipe * 0.7 {
                                onDelete()
                            } else if raw <= -buttonWidth * 0.5 {
                                settle(-buttonWidth)
                            } else {
                                // Always springs back on the leading edge —
                                // the action fires from the gesture itself.
                                // `resting == 0` so that swiping right merely
                                // to close a revealed Delete never shares.
                                let sharing = !cancelled && resting == 0 && raw >= shareThreshold
                                settle(0)
                                if sharing { onShare?() }
                            }
                        }
                    )
                    .allowsHitTesting(false)
                }
                .offset(x: offset)
                // The swipes are invisible to VoiceOver, which has no way to
                // perform them; these expose the same two actions in the rotor.
                .accessibilityAction(named: Text("Delete"), onDelete)
                .modifier(OptionalAccessibilityAction(name: Text("Share"), action: onShare))
                // Disabled while the swipe pan is active, so the row's own
                // button never gets to finish tracking that touch as a
                // press-then-tap — that stray tap-on-release was a real bug.
                // (Vertical scrolls cancel presses natively.)
                .allowsHitTesting(!isDragging)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .themeShadow(shadow ?? Theme.ShadowStyle(color: .clear, radius: 0))
    }

    private func settle(_ value: CGFloat) {
        resting = value
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            offset = value
        }
    }
}

/// Adds an accessibility action only when there is one — rows without a
/// leading swipe must not advertise a phantom "Share" in the rotor. The
/// branch is constant for the lifetime of a row, so view identity is stable.
private struct OptionalAccessibilityAction: ViewModifier {
    let name: Text
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.accessibilityAction(named: name, action)
        } else {
            content
        }
    }
}

/// Invisible overlay that feeds `SwipeToDelete` a horizontal pan via a UIKit
/// `UIPanGestureRecognizer`. The recognizer is attached to the enclosing
/// `UIScrollView` (touches are filtered to this row's frame) and its delegate
/// allows simultaneous recognition, so vertical scrolling and the row swipe
/// coexist on the same touch — the arbitration SwiftUI's `DragGesture` can't
/// opt into. It only begins on a clearly sideways lean; vertical and shallow
/// diagonal movement is left entirely to the scroll view.
private struct SwipePanCatcher: UIViewRepresentable {
    let onBegan: () -> Void
    /// Horizontal translation since the pan began.
    let onChanged: (CGFloat) -> Void
    /// Final translation; `cancelled` suppresses the full-swipe delete.
    let onEnded: (_ tx: CGFloat, _ cancelled: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.backgroundColor = .clear
        // The anchor is geometry only — it must never win hit-testing over
        // the row's own buttons. The pan lives on the scroll view instead.
        view.isUserInteractionEnabled = false
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        view.pan = pan
        context.coordinator.anchor = view
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        if let pan = uiView.pan { pan.view?.removeGestureRecognizer(pan) }
    }

    final class AnchorView: UIView {
        var pan: UIPanGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let pan else { return }
            pan.view?.removeGestureRecognizer(pan)
            guard window != nil else { return }
            var candidate = superview
            while let v = candidate, !(v is UIScrollView) { candidate = v.superview }
            (candidate ?? window)?.addGestureRecognizer(pan)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: () -> Void = {}
        var onChanged: (CGFloat) -> Void = { _ in }
        var onEnded: (CGFloat, Bool) -> Void = { _, _ in }
        weak var anchor: UIView?
        private var didBegin = false

        @objc func handlePan(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                // Drop the ~10pt activation lead so the row tracks the finger
                // from rest instead of jumping.
                pan.setTranslation(.zero, in: pan.view)
                didBegin = true
                onBegan()
            case .changed:
                onChanged(pan.translation(in: pan.view).x)
            case .ended:
                guard didBegin else { return }
                didBegin = false
                onEnded(pan.translation(in: pan.view).x, false)
            case .cancelled, .failed:
                guard didBegin else { return }
                didBegin = false
                onEnded(pan.translation(in: pan.view).x, true)
            default:
                break
            }
        }

        // Only touches that land on this row may start its swipe (many rows
        // share the one scroll view, each with its own recognizer).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard let anchor, anchor.window != nil else { return false }
            return anchor.bounds.contains(touch.location(in: anchor))
        }

        // Require a clear sideways lean before committing to a swipe; anything
        // vertical-ish stays a pure scroll.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let t = pan.translation(in: pan.view)
            return abs(t.x) > abs(t.y) * 1.5
        }

        // Simultaneous only with scroll-view pans (the vertical list, paging),
        // which is the whole point of using a UIKit recognizer. Everything
        // else — notably SwiftUI's tap recognizers on the row — stays
        // exclusive, so the moment the swipe begins UIKit forces them to
        // fail: releasing a partial swipe settles the row without the
        // release also firing as a tap.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
    }
}

// MARK: - Mono value pill

/// Small mono value chip (e.g. a date badge) on a soft fill.
struct MonoPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.mono(14, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Theme.softFill))
    }
}
