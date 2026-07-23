import SwiftUI

/// The five (four for Q) app sections, in tab order.
enum RootTab: Hashable {
    case watch, faces, fitness, alarms, settings

    var title: LocalizedStringResource {
        switch self {
        case .watch:    return "Watch"
        case .faces:    return "Faces"
        case .fitness:  return "Fitness"
        case .alarms:   return "Alarms"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .watch:    return "applewatch"
        case .faces:    return "circle.dashed"
        case .fitness:  return "heart.fill"
        case .alarms:   return "alarm.fill"
        case .settings: return "gearshape"
        }
    }
}

enum RootNavigationStyle: Equatable {
    case floatingTabBar
    case sidebar
}

/// Pure adaptive-layout decisions, kept separate from SwiftUI so transitions
/// and capability changes can be covered without rendering a view hierarchy.
enum RootLayout {
    static func navigationStyle(isPad: Bool,
                                horizontalSizeClass: UserInterfaceSizeClass?,
                                verticalSizeClass _: UserInterfaceSizeClass? = nil) -> RootNavigationStyle {
        isPad && horizontalSizeClass == .regular ? .sidebar : .floatingTabBar
    }

    static func tabs(hasFaces: Bool) -> [RootTab] {
        hasFaces ? [.watch, .faces, .fitness, .alarms, .settings]
                 : [.watch, .fitness, .alarms, .settings]
    }

    static func normalizedSelection(_ selection: RootTab, hasFaces: Bool) -> RootTab {
        tabs(hasFaces: hasFaces).contains(selection) ? selection : .watch
    }
}

/// Custom tab container hosting the app's screens under a floating brass tab
/// bar (handoff direction 1a). Replaces the stock `TabView` so the tab bar can
/// carry the redesign's identity; the Faces tab is present only when the
/// active watch has an e-ink display.
struct RootTabView: View {
    let hasFaces: Bool
    @StateObject private var importRouter = WatchfaceImportRouter.shared
    @State private var selection: RootTab = RootTabView.initialTab
    @State private var tabBarHeight: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Debug/screenshot hook: lets a UI test or a seeded default open a
    /// specific tab on launch. Defaults to Watch.
    private static var initialTab: RootTab {
        switch UserDefaults.standard.string(forKey: "debugInitialTab") {
        case "faces": return .faces
        case "fitness": return .fitness
        case "alarms": return .alarms
        case "settings": return .settings
        default: return .watch
        }
    }

    private var tabs: [RootTab] {
        RootLayout.tabs(hasFaces: hasFaces)
    }

    private var navigationStyle: RootNavigationStyle {
        RootLayout.navigationStyle(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
    }

    var body: some View {
        Group {
            switch navigationStyle {
            case .sidebar:
                sidebarContainer
            case .floatingTabBar:
                tabBarContainer
            }
        }
        .onAppear(perform: normalizeSelection)
        .onChange(of: hasFaces) { _, _ in normalizeSelection() }
        .onAppear(perform: routePendingWatchfaceImport)
        .onChange(of: importRouter.pendingImportURL) { _, _ in routePendingWatchfaceImport() }
    }

    /// Brings the Faces tab forward for a `.hbface` opened from outside the
    /// app; `WatchfacesView` does the actual import and clears the router.
    /// A watch with no e-ink display has no Faces tab at all, so the file is
    /// dropped here rather than left pending forever.
    private func routePendingWatchfaceImport() {
        guard importRouter.pendingImportURL != nil else { return }
        guard hasFaces else {
            importRouter.pendingImportURL = nil
            ToastCenter.shared.error(
                String(localized: "This watch has no display for watchfaces."))
            return
        }
        selection = .faces
    }

    @ViewBuilder private var selectedScreen: some View {
        switch selection {
        case .watch:    DashboardView()
        case .faces:    WatchfacesView()
        case .fitness:  FitnessView()
        case .alarms:   AlarmsView()
        case .settings: SettingsView()
        }
    }

    private var tabBarContainer: some View {
        // `safeAreaInset` here places the floating bar, but a `NavigationStack`
        // does not forward an ancestor's bottom inset to its own scrolling
        // content — so the bar's measured height is also handed to each screen
        // (via the environment) to reserve as scroll-content bottom padding.
        // Without this the last rows scroll under the bar (regressed with the
        // landscape/iPad rework, which swapped a fixed reserve for this inset).
        selectedScreen
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.floatingTabBarHeight, tabBarHeight)
            .background(Theme.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FossilTabBar(tabs: tabs, selection: $selection,
                             compactHeight: verticalSizeClass == .compact)
                    .padding(.bottom, 8)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: TabBarHeightPreferenceKey.self,
                                                   value: proxy.size.height)
                        }
                    )
            }
            .onPreferenceChange(TabBarHeightPreferenceKey.self) { tabBarHeight = $0 }
    }

    private var sidebarContainer: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Hybridge")
                    .font(Theme.serif(34))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                List(tabs, id: \.self) { tab in
                    Button {
                        selection = tab
                    } label: {
                        Label {
                            Text(tab.title)
                                .font(Theme.sans(16, weight: selection == tab ? .semibold : .regular,
                                                 relativeTo: .body))
                        } icon: {
                            Image(systemName: tab.symbol)
                                .frame(width: 24)
                        }
                        .foregroundStyle(selection == tab ? Theme.accent : Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selection == tab ? Theme.accentSoft : Color.clear)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .background(Theme.bg)
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            selectedScreen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
    }

    private func normalizeSelection() {
        selection = RootLayout.normalizedSelection(selection, hasFaces: hasFaces)
    }
}

/// Measured height of the floating tab bar, published from the bar's geometry
/// so hosted screens can reserve matching bottom space for their scroll content
/// (a `NavigationStack` swallows an ancestor's `safeAreaInset`, so the inset
/// alone doesn't reach the scroll views inside each tab).
private struct TabBarHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FloatingTabBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Height of the floating tab bar, or 0 when there is none (sidebar/iPad).
    /// Scroll screens add this to their bottom padding so content clears the bar.
    var floatingTabBarHeight: CGFloat {
        get { self[FloatingTabBarHeightKey.self] }
        set { self[FloatingTabBarHeightKey.self] = newValue }
    }
}

/// The floating rounded tab bar card.
struct FossilTabBar: View {
    let tabs: [RootTab]
    @Binding var selection: RootTab
    var compactHeight = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                let active = tab == selection
                Button {
                    selection = tab
                } label: {
                    tabLabel(tab, active: active)
                    .foregroundStyle(active ? Theme.accent : Theme.sub)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, compactHeight ? 6 : 10)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: compactHeight ? 20 : 26, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: compactHeight ? 20 : 26, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1))
        )
        .themeShadow(Theme.tabBarShadow)
        .padding(.horizontal, 14)
        .padding(.top, compactHeight ? 4 : 8)
    }

    @ViewBuilder private func tabLabel(_ tab: RootTab, active: Bool) -> some View {
        if compactHeight {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 16, weight: active ? .semibold : .regular))
                Text(tab.title)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minHeight: 24)
        } else {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 22, weight: active ? .semibold : .regular))
                    .frame(height: 24)
                Text(tab.title)
                    .font(.system(size: 10, weight: active ? .semibold : .medium))
            }
        }
    }
}
