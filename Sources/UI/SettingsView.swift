import SwiftUI

/// Settings — "Warm brass" redesign: the tamed form. Icon-led grouped cards
/// with progressive disclosure; key controls inline, the rest behind chevrons
/// to detail screens. All existing behaviour and capability gating preserved.
struct SettingsView: View {
    @EnvironmentObject var watch: WatchManager
    @EnvironmentObject var registry: WatchRegistry
    @AppStorage("stepGoal") private var stepGoal = 10000
    @AppStorage("vibrationStrength") private var vibrationStrength = 100
    @AppStorage("useMetric") private var useMetric = true
    @State private var stepGoalPushTask: Task<Void, Never>?

    @ObservedObject private var weather = WeatherProvider.shared
    @ObservedObject private var calendarSync = CalendarSync.shared
    @State private var weatherEnabled = WeatherProvider.shared.isEnabled
    @State private var calendarEnabled = CalendarSync.shared.isEnabled
    @State private var quietEffective = QuietHoursManager.shared.effectiveMode
    @AppStorage("heartRateMode") private var heartRateMode = -1
    @State private var batteryAlertEnabled = BatteryWatcher.shared.isEnabled
    @State private var batteryAlertThreshold = BatteryWatcher.shared.threshold
    @State private var batteryPermissionDenied = false
    @State private var showOnboarding = false
    @State private var refreshToken = 0
    @State private var homeAssistantAdded = HomeAssistantSettingsStore.isAdded

    /// Active watch family — gates the sections that only exist on one.
    private var kind: WatchKind {
        registry.activeWatch?.kind ?? .hybridHR
    }

    var body: some View {
        NavigationStack {
            ThemedScreen("Settings") {
                healthGroup
                featuresGroup
                alertsGroup
                if kind.hasJsonPush {
                    advancedGroup
                }
                aboutFooter
            }
            .toolbar(.hidden, for: .navigationBar)
            .onReceive(NotificationCenter.default.publisher(for: .activeWatchChanged)) { _ in
                quietEffective = QuietHoursManager.shared.effectiveMode
                refreshToken += 1
            }
            .task { refreshBatteryPermission(); quietEffective = QuietHoursManager.shared.effectiveMode }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.willEnterForegroundNotification)) { _ in
                refreshBatteryPermission()
                quietEffective = QuietHoursManager.shared.effectiveMode
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .homeAssistantIntegrationChanged)) { _ in
                homeAssistantAdded = HomeAssistantSettingsStore.isAdded
            }
            .sheet(isPresented: $showOnboarding) { OnboardingView() }
        }
        .tint(Theme.accent)
    }

    // MARK: Health

    private var healthGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Health")
            ThemedCard {
                if kind.hasWorkouts {
                    navRow(icon: "figure.walk.motion", title: "Activity detection",
                           destination: { ActivityDetectionView() })
                    Hairline(leading: 59)
                }
                if kind.hasHeartRate {
                    segmentedRow(icon: "waveform.path.ecg", title: "Heart rate",
                                 selection: $heartRateMode,
                                 options: [(-1, "Automatic"), (0, "Off")]) {
                        applyConfig([.heartRateMode(Int8($0))], success: "Heart rate mode updated")
                    }
                    Hairline(leading: 59)
                }
                SettingsRow(icon: "target", title: "Daily step goal") {
                    StepperPill(text: stepGoal.grouped,
                                onMinus: { stepGoal = max(1000, stepGoal - 1000) },
                                onPlus: { stepGoal = min(50000, stepGoal + 1000) })
                }
                if kind.hasHeartRate {
                    Hairline(leading: 59)
                    navRow(icon: "person", title: "Body metrics",
                           value: bodyMetricsSummary, mono: true,
                           destination: { BodyMetricsView() })
                }
            }
            .onChange(of: stepGoal) { _, value in pushStepGoalDebounced(value) }
            Footer("These preferences apply to every compatible watch when it connects. Body metrics let supported watches estimate calories.")
        }
        .id(refreshToken)   // recompute the summary after editing
    }

    private var bodyMetricsSummary: String {
        let h = UserDefaults.standard.object(forKey: "bodyHeightCm") as? Int ?? 170
        let w = UserDefaults.standard.object(forKey: "bodyWeightKg") as? Int ?? 70
        return String(localized: "\(h) cm · \(w) kg")
    }

    // MARK: Watch features (notifications / apps / buttons)

    private var featuresGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Notifications & apps").padding(.top, 22)
            ThemedCard {
                segmentedRow(icon: "waveform", title: "Vibration",
                             selection: $vibrationStrength,
                             options: [(25, "Light"), (50, "Medium"), (100, "Strong")]) {
                    guard kind != .misfitQ else { return }
                    applyConfig([.vibrationStrength(UInt8($0))], success: "Vibration updated")
                }
                if kind.hasApps {
                    Hairline(leading: 59)
                    navRow(icon: "bell.badge", title: "Notifications", destination: { NotificationsView() })
                    Hairline(leading: 59)
                    navRow(icon: "app.badge", title: "Apps", destination: { AppsView() })
                    Hairline(leading: 59)
                    navRow(icon: "hand.tap", title: "Button assignments", destination: { ButtonsView() })
                } else if kind.hasHandNotificationConfig {
                    Hairline(leading: 59)
                    navRow(icon: "bell.badge", title: "Notifications", destination: { QNotificationsView() })
                    Hairline(leading: 59)
                    navRow(icon: "hand.tap", title: "Button assignments", destination: { QButtonsView() })
                }
            }
            Footer("These preferences are shared by all compatible watches and applied when they connect.")
        }
    }

    // MARK: Alerts & features

    private var alertsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Alerts & features").padding(.top, 22)
            ThemedCard {
                SettingsRow(icon: "ruler", title: "Metric units") {
                    Toggle(isOn: $useMetric) { EmptyView() }.labelsHidden().brassToggle()
                        .accessibilityLabel("Metric units")
                }
                .onChange(of: useMetric) { _, on in
                    guard kind != .misfitQ else { return }
                    applyConfig([.units(on ? 8 : (8 | 4 | 1))], success: "Units updated")
                }
                if kind.hasQuietHours {
                    Hairline(leading: 59)
                    navRow(icon: "moon", title: "Quiet hours",
                           destination: { QuietHoursSettingsView(onChange: {
                               quietEffective = QuietHoursManager.shared.effectiveMode }) }) {
                        if quietEffective == .night {
                            Text("Quiet now")
                                .font(Theme.sans(13, weight: .semibold, relativeTo: .footnote))
                                .foregroundStyle(Theme.accent)
                                .padding(.vertical, 4).padding(.horizontal, 9)
                                .background(Capsule().fill(Theme.accent.opacity(0.12)))
                        }
                    }
                }
                if kind.hasWeather {
                    Hairline(leading: 59)
                    SettingsRow(icon: "cloud", title: "Weather") {
                        Toggle(isOn: $weatherEnabled) { EmptyView() }.labelsHidden().brassToggle()
                            .onChange(of: weatherEnabled) { _, on in
                                weather.isEnabled = on
                                if on { Task { await weather.pushIfEnabled() } }
                            }
                    }
                }
                if kind.hasCalendar {
                    Hairline(leading: 59)
                    SettingsRow(icon: "calendar", title: "Calendar") {
                        Toggle(isOn: $calendarEnabled) { EmptyView() }.labelsHidden().brassToggle()
                            .onChange(of: calendarEnabled) { _, on in
                                calendarSync.isEnabled = on
                                if on { Task { await calendarSync.syncNow() } }
                            }
                    }
                }
                Hairline(leading: 59)
                SettingsRow(icon: "battery.25", iconTint: Theme.warn, iconFill: Theme.warnSoft,
                            title: "Low-battery alert") {
                    Toggle(isOn: $batteryAlertEnabled) { EmptyView() }.labelsHidden().brassToggle()
                        .onChange(of: batteryAlertEnabled) { _, on in
                            BatteryWatcher.shared.isEnabled = on
                            if on { refreshBatteryPermission(delay: 1) }
                        }
                }
                if batteryAlertEnabled {
                    Hairline(leading: 59)
                    SettingsRow(icon: "gauge", title: "Warn below") {
                        StepperPill(text: "\(batteryAlertThreshold)%",
                                    onMinus: { setThreshold(batteryAlertThreshold - 5) },
                                    onPlus: { setThreshold(batteryAlertThreshold + 5) })
                    }
                    if batteryPermissionDenied {
                        Hairline(leading: 59)
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("Notifications are off — open Settings")
                                Spacer()
                            }
                            .font(Theme.sans(14, relativeTo: .subheadline)).foregroundStyle(Theme.warn)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }.buttonStyle(PressableRow())
                    }
                }
            }
            Footer("Blocks every notification on the watch during quiet hours. Low-battery notifies once per charge when the level drops below the threshold.")
        }
    }

    private func setThreshold(_ value: Int) {
        batteryAlertThreshold = min(50, max(5, value))
        BatteryWatcher.shared.threshold = batteryAlertThreshold
    }

    // MARK: Advanced

    private var advancedGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Advanced").padding(.top, 22)
            ThemedCard {
                navRow(icon: "location", title: "Workout GPS", destination: { WorkoutGPSDemoView() })
                Hairline(leading: 59)
                navRow(icon: "puzzlepiece.extension", title: "Integrations",
                       value: homeAssistantAdded ? String(localized: "1 added") : nil,
                       destination: { IntegrationsView() })
            }
            Footer("Add optional phone-side integrations used by watch apps.")
        }
    }

    // MARK: About

    private var aboutFooter: some View {
        VStack(spacing: 6) {
            Text("Hybridge · unofficial companion · v\(Self.displayVersion)")
                .font(Theme.sans(12, relativeTo: .caption))
                .foregroundStyle(Theme.sub)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            // WeatherKit terms require visible attribution wherever its data
            // is used; the watch weather push is fed by WeatherKit.
            Link(" Weather", destination:
                    URL(string: "https://weatherkit.apple.com/legal-attribution.html")!)
                .font(Theme.sans(12, relativeTo: .caption))
                .tint(Theme.sub)
            Button("Show welcome tour again") {
                UserDefaults.standard.set(false, forKey: OnboardingView.seenKey)
                showOnboarding = true
            }
            .font(Theme.sans(13, relativeTo: .footnote))
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private static var displayVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    // MARK: Row builders

    /// A chevron row that navigates to a detail screen.
    private func navRow<D: View>(icon: String, title: LocalizedStringResource, value: String? = nil,
                                 mono: Bool = false,
                                 @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink { destination() } label: {
            SettingsRow(icon: icon, title: title, showChevron: true) {
                if let value {
                    Text(value)
                        .font(mono ? Theme.mono(14) : Theme.sans(15, relativeTo: .body))
                        .foregroundStyle(Theme.sub)
                }
            }
        }.buttonStyle(PressableRow())
    }

    /// Overload allowing a custom trailing accessory (e.g. the "Quiet now" pill).
    private func navRow<D: View, T: View>(icon: String, title: LocalizedStringResource,
                                          @ViewBuilder destination: @escaping () -> D,
                                          @ViewBuilder trailing: @escaping () -> T) -> some View {
        NavigationLink { destination() } label: {
            SettingsRow(icon: icon, title: title, showChevron: true, trailing: trailing)
        }.buttonStyle(PressableRow())
    }

    /// A row whose control is a segmented picker on its own line below (mock's
    /// vibration layout). `apply` runs on change for immediate-write controls.
    private func segmentedRow<T: Hashable>(icon: String, title: LocalizedStringResource,
                                           selection: Binding<T>,
                                           options: [(T, LocalizedStringResource)],
                                           apply: ((T) -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                IconTile(symbol: icon)
                Text(title).font(Theme.sans(16, relativeTo: .body))
                Spacer()
            }
            ThemedSegmented(options: options.map { (value: $0.0, label: $0.1) },
                            selection: selection)
                .padding(.leading, 43)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .onChange(of: selection.wrappedValue) { _, new in apply?(new) }
    }

    // MARK: Actions (unchanged behaviour)

    private func refreshBatteryPermission(delay: TimeInterval = 0) {
        Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            batteryPermissionDenied = await BatteryWatcher.shared.permissionDenied()
        }
    }

    private func applyConfig(_ items: [ConfigItem], success: LocalizedStringResource) {
        Task {
            do {
                try await watch.writeConfig(items)
                await MainActor.run { ToastCenter.shared.success(String(localized: success)) }
            } catch {
                // Not connected right now: the reapply-on-init helper lands
                // this once the watch is back, so a toast here would just be
                // noise every time the app is opened offline.
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }

    /// Coalesces rapid ± taps on the step goal into one watch write, silent
    /// on success — the ring already updated locally, so a toast per tap
    /// would be noise.
    private func pushStepGoalDebounced(_ value: Int) {
        stepGoalPushTask?.cancel()
        stepGoalPushTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard kind != .misfitQ else { return }
            do {
                try await watch.writeConfig([.dailyStepGoal(UInt32(value))])
            } catch {
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }

}

private extension Int {
    var grouped: String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

// MARK: - Detail sub-screens (native styling; not part of the handoff mocks)

/// Body metrics editor. Stores one profile and pushes it to every compatible
/// watch as it connects.
struct BodyMetricsView: View {
    @EnvironmentObject var watch: WatchManager
    @State private var heightCm = UserDefaults.standard.object(forKey: "bodyHeightCm") as? Int ?? 170
    @State private var weightKg = UserDefaults.standard.object(forKey: "bodyWeightKg") as? Int ?? 70
    @State private var gender = UserDefaults.standard.object(forKey: "bodyGender") as? Int ?? ConfigItem.Gender.male.rawValue
    @State private var birth = BodyMetricsView.storedBirthDate()
    @State private var pushTask: Task<Void, Never>?

    static func storedBirthDate() -> Date {
        if let ts = UserDefaults.standard.object(forKey: "bodyBirth") as? Double {
            return Date(timeIntervalSince1970: ts)
        }
        return DateComponents(calendar: .current, year: 1990, month: 1, day: 1).date ?? Date()
    }

    var body: some View {
        Form {
            Section {
                Stepper("Height: \(heightCm) cm", value: $heightCm, in: 100...250)
                Stepper("Weight: \(weightKg) kg", value: $weightKg, in: 30...250)
                Picker("Gender", selection: $gender) {
                    Text("Male").tag(ConfigItem.Gender.male.rawValue)
                    Text("Female").tag(ConfigItem.Gender.female.rawValue)
                    Text("Non-binary").tag(ConfigItem.Gender.nonBinary.rawValue)
                }
                DatePicker("Date of birth", selection: $birth, in: ...Date(), displayedComponents: .date)
            } footer: {
                Text("Changes are sent automatically. The watch stores your date of birth as an age in whole years and refreshes it each time it connects.")
            }
        }
        .navigationTitle("Body metrics")
        .themedList()
        .tint(Theme.accent)
        .onChange(of: heightCm) { _, _ in persistAndSchedulePush() }
        .onChange(of: weightKg) { _, _ in persistAndSchedulePush() }
        .onChange(of: gender) { _, _ in persistAndSchedulePush() }
        .onChange(of: birth) { _, _ in persistAndSchedulePush() }
    }

    private func persistAndSchedulePush() {
        let defaults = UserDefaults.standard
        defaults.set(heightCm, forKey: "bodyHeightCm")
        defaults.set(weightKg, forKey: "bodyWeightKg")
        defaults.set(gender, forKey: "bodyGender")
        defaults.set(birth.timeIntervalSince1970, forKey: "bodyBirth")
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled,
                  WatchRegistry.activeKindSync().hasHeartRate,
                  watch.connectionState == .ready, watch.isAuthenticated else { return }
            do {
                let g = ConfigItem.Gender(rawValue: gender) ?? .male
                try await watch.setBodyProfile(gender: g, heightCm: heightCm, weightKg: weightKg, birthDate: birth)
            } catch {
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }
}

/// Full quiet-hours schedule editor (moved out of the Settings list).
struct QuietHoursSettingsView: View {
    var onChange: () -> Void = {}
    @State private var enabled = QuietHoursManager.shared.schedule.enabled
    @State private var start = QuietHoursSettingsView.date(fromMinutes: QuietHoursManager.shared.schedule.startMinutes)
    @State private var end = QuietHoursSettingsView.date(fromMinutes: QuietHoursManager.shared.schedule.endMinutes)
    @State private var nowOn = QuietHoursManager.shared.overrideMode == .night
    @State private var effective = QuietHoursManager.shared.effectiveMode

    var body: some View {
        Form {
            Section {
                Toggle("Enable quiet hours", isOn: $enabled)
                    .onChange(of: enabled) { _, v in update { $0.enabled = v } }
                if enabled {
                    DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                        .onChange(of: start) { _, v in update { $0.startMinutes = Self.minutes(from: v) } }
                    DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                        .onChange(of: end) { _, v in update { $0.endMinutes = Self.minutes(from: v) } }
                }
                Toggle("Quiet now", isOn: $nowOn)
                    .onChange(of: nowOn) { _, v in
                        Task {
                            await QuietHoursManager.shared.setOverride(v ? .night : nil)
                            await MainActor.run { effective = QuietHoursManager.shared.effectiveMode; onChange() }
                        }
                    }
                LabeledContent("Currently", value: effective == .night
                               ? String(localized: "Quiet") : String(localized: "Normal"))
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Blocks every notification on the watch during the window — there's no per-app level, just on or off. While backgrounded, the swap lands within minutes to about an hour of the boundary; instantly when you open the app or the watch reconnects.")
            }
        }
        .navigationTitle("Quiet hours")
        .themedList()
        .tint(Theme.accent)
    }

    private func update(_ change: (inout QuietSchedule) -> Void) {
        var schedule = QuietHoursManager.shared.schedule
        change(&schedule)
        QuietHoursManager.shared.schedule = schedule
        Task {
            await QuietHoursManager.shared.evaluate()
            await MainActor.run { effective = QuietHoursManager.shared.effectiveMode; onChange() }
        }
    }

    static func date(fromMinutes minutes: Int) -> Date {
        var c = DateComponents(); c.hour = minutes / 60; c.minute = minutes % 60
        return Calendar.current.date(from: c) ?? Date()
    }

    static func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
