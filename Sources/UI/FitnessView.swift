import SwiftUI
import Charts
import UIKit

/// Fitness tab — "Warm brass" redesign. Themed cards over the existing
/// FitnessStore / HealthKitExporter data; Swift Charts restyled to the palette.
struct FitnessView: View {
    @EnvironmentObject var watch: WatchManager
    @EnvironmentObject var registry: WatchRegistry
    @StateObject private var fitness = FitnessStore.shared
    @StateObject private var health = HealthKitExporter.shared
    @State private var selectedDay = Date()
    @State private var showDayPicker = false
    @State private var busyText: String?
    @State private var confirmingHistoryDeletion = false
    @State private var chartVisibleDuration: TimeInterval = 86400
    @State private var chartScrollPosition = Date()
    @State private var chartViewportInitialized = false
    @State private var quarantinedActivity: ActivityQuarantineRecord?
    @State private var quarantinedActivityURL: URL?
    @AppStorage("healthAutoExportEnabled") private var autoExportEnabled = false

    private var kind: WatchKind {
        registry.activeWatch?.kind ?? .hybridHR
    }

    /// The x-axis range for the steps/heart-rate charts. For today this is a
    /// rolling last-24h window (so the empty early-morning hours don't waste
    /// half the chart); for a past day it's that day, midnight to midnight.
    private var chartWindow: ClosedRange<Date> {
        if Calendar.current.isDateInToday(selectedDay) {
            let now = Date()
            return now.addingTimeInterval(-86400)...now
        }
        let start = Calendar.current.startOfDay(for: selectedDay)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86400)
        return start...end
    }

    /// The portion of `chartWindow` currently visible after zooming and
    /// scrolling. Both charts share it so their time axes stay aligned.
    private var visibleChartWindow: ClosedRange<Date> {
        let fullDuration = chartWindow.upperBound.timeIntervalSince(chartWindow.lowerBound)
        let duration = min(max(chartVisibleDuration, 0), fullDuration)
        let latestStart = chartWindow.upperBound.addingTimeInterval(-duration)
        let start = min(max(chartScrollPosition, chartWindow.lowerBound), latestStart)
        return start...start.addingTimeInterval(duration)
    }

    var body: some View {
        NavigationStack {
            ThemedScreen("Fitness") {
                Text(introLine)
                    .font(Theme.sans(13, relativeTo: .footnote))
                    .foregroundStyle(Theme.sub)
                    .lineSpacing(2)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let busyText {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busyText).font(Theme.sans(13, relativeTo: .footnote)).foregroundStyle(Theme.sub)
                    }
                    .padding(.horizontal, 4).padding(.top, 8)
                }

                if let quarantinedActivity {
                    activityQuarantineCard(quarantinedActivity)
                }

                group("Today") { todayCard }
                group("Steps") { stepsCard }
                if kind.hasHeartRate { group("Heart rate") { heartRateCard } }
                group("Sleep & wellness") { sleepCard }
                    .padding(.bottom, 0)
                Footer("Sleep and SpO₂ are inferred from movement and heart-rate samples; treat them as estimates, not medical readings.")

                exportButton.padding(.top, 20)
                Button("Delete local fitness history", role: .destructive) {
                    confirmingHistoryDeletion = true
                }
                .font(Theme.sans(14, weight: .semibold, relativeTo: .footnote))
                .padding(.top, 20)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showDayPicker) {
                dayPickerSheet
            }
            .confirmationDialog("Delete local fitness history?",
                                isPresented: $confirmingHistoryDeletion,
                                titleVisibility: .visible) {
                Button("Delete history", role: .destructive) {
                    runBusy("Deleting fitness history…") {
                        guard await fitness.deleteAllHistory() else {
                            throw FitnessStoreDeletionError.failed
                        }
                        return "Local fitness history deleted. Apple Health data is unchanged."
                    }
                }
            } message: {
                Text("This permanently removes activity, heart-rate, SpO₂, sleep, workout and sync history stored by Hybridge on this iPhone. Data already exported to Apple Health is not removed.")
            }
            .onAppear {
                guard !chartViewportInitialized else { return }
                chartViewportInitialized = true
                resetChartViewport()
            }
            .onChange(of: selectedDay) { _, _ in
                resetChartViewport()
            }
            .task(id: registry.activeWatchID) {
                await refreshActivityQuarantine()
            }
        }
    }

    // MARK: Layout helpers

    private func activityQuarantineCard(_ record: ActivityQuarantineRecord) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Activity sync needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.sans(16, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(Theme.accent)
                Text("The watch's activity file could not be read safely. Hybridge kept it on the watch and saved a diagnostic copy on this iPhone. Automatic sync will wait until the watch replaces the file.")
                    .font(Theme.sans(13, relativeTo: .footnote))
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(record.length.formatted()) bytes · retry \(record.retryCount.formatted())")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.sub)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { quarantineActions }
                    VStack(alignment: .leading, spacing: 10) { quarantineActions }
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier("fitness.activityQuarantine")
    }

    @ViewBuilder private var quarantineActions: some View {
        Button("Retry now") {
            runBusy("Retrying activity sync…") {
                _ = try await watch.syncActivity(retryQuarantined: true)
                await refreshActivityQuarantine()
                return "Activity sync retry finished."
            }
        }
        .disabled(busyText != nil || watch.connectionState != .ready)

        if let quarantinedActivityURL {
            ShareLink(item: quarantinedActivityURL) {
                Label("Export raw file", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func refreshActivityQuarantine() async {
        guard let watchID = registry.activeWatchID else {
            quarantinedActivity = nil
            quarantinedActivityURL = nil
            return
        }
        let record = await ActivityQuarantineStore.shared.record(for: watchID)
        let url = await ActivityQuarantineStore.shared.exportURL(for: watchID)
        await MainActor.run {
            quarantinedActivity = record
            quarantinedActivityURL = url
        }
    }

    /// A labelled section: small uppercase label + card, with top spacing.
    private func group<C: View>(_ label: LocalizedStringResource,
                                @ViewBuilder _ card: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(label).padding(.top, 24)
            card()
        }
    }

    private var introLine: String {
        if let last = fitness.lastSyncDate {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
            return String(localized: "Activity syncs automatically while connected, including in the background. Last sync \(f.localizedString(for: last, relativeTo: Date())).")
        }
        return String(localized: "Activity syncs automatically while connected, including in the background.")
    }

    // MARK: Today card

    private var todayCard: some View {
        ThemedCard {
            HStack(spacing: 0) {
                StatTile(symbol: "figure.walk", value: totalSteps(onDay: Date()).formatted(), label: "steps")
                TileDivider()
                StatTile(symbol: "flame.fill", value: fitness.calories(onDay: Date()).formatted(), label: "kcal")
                TileDivider()
                StatTile(symbol: "bolt.fill", value: fitness.activeMinutes(onDay: Date()).formatted(), label: "active min")
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 8)

            if kind.hasHeartRate {
                Hairline(leading: 0)
                liveHeartRateRow
            }
        }
    }

    private var liveHeartRateRow: some View {
        HStack(spacing: 12) {
            PulsingHeart(active: watch.liveHeartRateActive)
            VStack(alignment: .leading, spacing: 1) {
                Text("Live heart rate").font(Theme.sans(16, weight: .semibold, relativeTo: .body))
                Text(heartRateSubtitle)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
            Toggle(isOn: Binding(
                get: { watch.liveHeartRateActive },
                set: { watch.setLiveHeartRate($0) }
            )) { EmptyView() }.labelsHidden().brassToggle()
                .accessibilityLabel("Live heart rate")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var heartRateSubtitle: String {
        if watch.liveHeartRateActive {
            return watch.liveHeartRate.map { String(localized: "\($0) bpm · live") }
                ?? String(localized: "measuring…")
        }
        if let latest = fitness.latestHeartRate {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
            return String(localized: "\(latest.bpm) bpm · \(f.localizedString(for: latest.date, relativeTo: Date()))")
        }
        return String(localized: "off")
    }

    // MARK: Steps card

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThemedCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Day").font(Theme.sans(15, weight: .semibold, relativeTo: .body))
                        Spacer()
                        Button { showDayPicker = true } label: {
                            MonoPill(text: selectedDay.formatted(.dateTime.day().month().year()))
                        }.buttonStyle(.plain)
                    }

                    let window = chartWindow
                    let bucketMinutes = FitnessStepBuckets.minutes(
                        for: chartVisibleDuration
                    )
                    let bars = fitness.steps(inBucketsOf: bucketMinutes,
                                             from: window.lowerBound,
                                             to: window.upperBound)
                        .map { StepBar(start: $0.start, end: $0.end, steps: $0.steps) }
                    if bars.allSatisfy({ $0.steps == 0 }) {
                        Text("No step data for this period.")
                            .font(Theme.sans(13, relativeTo: .footnote)).foregroundStyle(Theme.sub)
                            .frame(height: 104, alignment: .center)
                            .frame(maxWidth: .infinity)
                    } else {
                        StepsChartView(bars: bars,
                                       domain: window,
                                       visibleDuration: $chartVisibleDuration,
                                       scrollPosition: $chartScrollPosition)
                    }
                }
                .padding(16)
            }
            Footer("Today's total is read from the watch's step counter. The graph is reconstructed from synced minute samples and may not add up.")
        }
    }

    // MARK: Heart rate card

    private var heartRateCard: some View {
        let window = chartWindow
        let series = fitness.heartRateSeries(from: window.lowerBound, to: window.upperBound)
        let visibleSeries = series.filter { visibleChartWindow.contains($0.date) }
        return ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                if series.isEmpty {
                    Text("No heart-rate data for this period.")
                        .font(Theme.sans(13, relativeTo: .footnote)).foregroundStyle(Theme.sub)
                        .frame(height: 96, alignment: .center).frame(maxWidth: .infinity)
                } else {
                    let bpms = visibleSeries.map(\.bpm)
                    let bpmSummary = bpms.isEmpty
                        ? "— \(String(localized: "bpm"))"
                        : String(localized: "\(bpms.min() ?? 0)–\(bpms.max() ?? 0) bpm")
                    Text(bpmSummary)
                        .font(Theme.mono(24, weight: .semibold))
                        .foregroundStyle(Theme.ink)

                    let points = series.map { HRPoint(date: $0.date, bpm: $0.bpm) }
                    Chart(points) { p in
                        AreaMark(x: .value("Time", p.date), y: .value("BPM", p.bpm))
                            .foregroundStyle(LinearGradient(
                                colors: [Theme.danger.opacity(0.18), Theme.danger.opacity(0)],
                                startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.date), y: .value("BPM", p.bpm))
                            .foregroundStyle(Theme.danger)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 40...180)
                    .chartXAxis {
                        FitnessTimeAxis.marks(visibleDuration: chartVisibleDuration)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [40, 80, 120, 160]) { _ in
                            AxisGridLine().foregroundStyle(Theme.line)
                            AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.sub)
                        }
                    }
                    .fitnessChartViewport(domain: window,
                                          visibleDuration: $chartVisibleDuration,
                                          scrollPosition: $chartScrollPosition)
                    .frame(height: 96)
                }
            }
            .padding(16)
        }
    }

    // MARK: Sleep & wellness card

    private var sleepCard: some View {
        let sessions = fitness.sleepSessions(nightEnding: selectedDay)
        let sleepTotal = sessions.reduce(0) { $0 + $1.duration }
        return ThemedCard {
            NavigationLink { SleepView() } label: {
                wellnessRow("Sleep (inferred)",
                            value: sessions.isEmpty ? "—" : String(
                                localized: "\(sleepTotal / 3600) h \((sleepTotal % 3600) / 60) min"),
                            chevron: true)
            }.buttonStyle(PressableRow())

            if let spo2 = spo2Range {
                Hairline()
                wellnessRow("SpO₂ range", value: spo2, chevron: false)
            }

            Hairline()
            NavigationLink { WorkoutsView() } label: {
                wellnessRow("Workouts", value: workoutsThisWeek, chevron: true, valueMuted: true)
            }.buttonStyle(PressableRow())

            Hairline()
            NavigationLink { WellnessView() } label: {
                wellnessRow("Wellness trends", value: "", chevron: true)
            }.buttonStyle(PressableRow())
        }
    }

    private func wellnessRow(_ title: LocalizedStringResource, value: String,
                             chevron: Bool, valueMuted: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.sans(16, relativeTo: .body)).foregroundStyle(Theme.ink)
            Spacer()
            Text(value)
                .font(valueMuted ? .system(size: 15) : Theme.mono(15, weight: .semibold))
                .foregroundStyle(valueMuted ? Theme.sub : Theme.ink)
            if chevron { Chevron() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var spo2Range: String? {
        guard !fitness.spo2Samples.isEmpty else { return nil }
        let vals = fitness.spo2Samples.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else { return nil }
        return lo == hi
            ? String(localized: "\(lo)%")
            : String(localized: "\(lo)–\(hi)%")
    }

    private var workoutsThisWeek: String {
        let weekAgo = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        let count = fitness.workouts.filter { Double($0.startTimestamp) >= weekAgo }.count
        return count == 0 ? String(localized: "None") : String(localized: "\(count) this week")
    }

    // MARK: Export

    private var exportButton: some View {
        Button {
            runBusy("Exporting to Apple Health…") {
                let count = try await health.exportNewSamples(from: fitness)
                return "Exported \(count) samples to Apple Health."
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                Text("Export to Apple Health")
            }
            .font(Theme.sans(16, weight: .semibold, relativeTo: .body))
            .foregroundStyle(Theme.bg)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.ink))
        }
        .buttonStyle(.plain)
        .disabled(!health.isAvailable || busyText != nil)
        .opacity(health.isAvailable ? 1 : 0.5)
    }

    // MARK: Day picker sheet

    private var dayPickerSheet: some View {
        NavigationStack {
            VStack {
                DatePicker("Day", selection: $selectedDay, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Theme.accent)
                    .padding()
                Spacer()
            }
            .navigationTitle("Choose a day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showDayPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: Data helpers (unchanged behaviour)

    /// Daily step total. Today includes the latest counters seen from every
    /// watch; past days use the persisted minute samples.
    private func totalSteps(onDay day: Date) -> Int {
        if Calendar.current.isDateInToday(day) {
            return fitness.stepsIncludingLive(onDay: day)
        }
        return fitness.steps(onDay: day)
    }

    private func resetChartViewport() {
        let window = chartWindow
        chartVisibleDuration = window.upperBound.timeIntervalSince(window.lowerBound)
        chartScrollPosition = window.lowerBound
    }

    private func runBusy(_ message: LocalizedStringResource,
                         _ action: @escaping () async throws -> LocalizedStringResource) {
        busyText = String(localized: message)
        Task {
            do {
                let result = try await action()
                await MainActor.run {
                    busyText = nil
                    ToastCenter.shared.success(String(localized: result))
                }
            } catch {
                await MainActor.run { busyText = nil; ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }
}

private enum FitnessStoreDeletionError: LocalizedError {
    case failed
    var errorDescription: String? { String(localized: "Could not delete all local fitness files") }
}

/// Chart-friendly (Identifiable) wrappers — Swift Charts can't key a plain
/// tuple array, and FitnessStore returns tuples.
private struct StepBar: Identifiable {
    let start: Date
    let end: Date
    let steps: Int
    var id: Date { start }
}
private struct HRPoint: Identifiable { let date: Date; let bpm: Int; var id: Date { date } }

/// The steps histogram uses time intervals rather than fixed-width marks, so
/// adjacent aggregation buckets touch at every zoom level.
private struct StepsChartView: View {
    let bars: [StepBar]
    let domain: ClosedRange<Date>
    @Binding var visibleDuration: TimeInterval
    @Binding var scrollPosition: Date
    @State private var selectedDate: Date?

    private var maxSteps: Int { max(bars.map(\.steps).max() ?? 1, 1) }

    private var selected: StepBar? {
        guard let selectedDate else { return nil }
        return bars.first {
            selectedDate >= $0.start && selectedDate < $0.end
        }
    }

    var body: some View {
        Chart {
            ForEach(bars) { bar in
                RectangleMark(xStart: .value("Start", insetStart(for: bar)),
                              xEnd: .value("End", insetEnd(for: bar)),
                              yStart: .value("Baseline", 0),
                              yEnd: .value("Steps", bar.steps))
                    .foregroundStyle(barColor(bar.steps))
                    .cornerRadius(2, style: .continuous)
                    .opacity(selected == nil || selected?.start == bar.start ? 1 : 0.35)
            }
            if let selected {
                RuleMark(x: .value("Time", selected.start))
                    .foregroundStyle(Theme.sub.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .annotation(position: .top, spacing: 4) {
                        tooltip(for: selected)
                    }
            }
        }
        .chartXAxis {
            FitnessTimeAxis.marks(visibleDuration: visibleDuration)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.sub)
            }
        }
        .fitnessChartViewport(domain: domain,
                              visibleDuration: $visibleDuration,
                              scrollPosition: $scrollPosition)
        .chartXSelection(value: $selectedDate)
        .frame(height: 120)
    }

    private func barColor(_ steps: Int) -> Color {
        let f = Double(steps) / Double(maxSteps)
        if f >= 0.55 { return Theme.accent }
        if f >= 0.25 { return Theme.barMid }
        return Theme.barLow
    }

    /// Leave an 8% total gap between neighboring time intervals. Because it
    /// is proportional to the bucket duration, the visual spacing stays nearly
    /// constant as the aggregation level changes while zooming.
    private func insetStart(for bar: StepBar) -> Date {
        bar.start.addingTimeInterval(bar.end.timeIntervalSince(bar.start) * 0.04)
    }

    private func insetEnd(for bar: StepBar) -> Date {
        bar.end.addingTimeInterval(-bar.end.timeIntervalSince(bar.start) * 0.04)
    }

    private func tooltip(for bar: StepBar) -> some View {
        let startText = bar.start.formatted(date: .omitted, time: .shortened)
        let endText = bar.end.formatted(date: .omitted, time: .shortened)
        return VStack(spacing: 1) {
            Text("\(bar.steps)").font(Theme.mono(13, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(String(localized: "\(startText)–\(endText)"))
                .font(Theme.mono(9)).foregroundStyle(Theme.sub)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

/// Picks a friendly clock interval nearest to one twenty-fourth of the visible
/// time span. All choices divide a day evenly, so bucket boundaries stay stable
/// while the user pans sideways.
private enum FitnessStepBuckets {
    private static let choices = [1, 2, 3, 5, 6, 10, 12, 15, 20, 30, 40, 60, 90, 120]

    static func minutes(for visibleDuration: TimeInterval) -> Int {
        let target = visibleDuration / 60 / 24
        return choices.min {
            abs(Double($0) - target) < abs(Double($1) - target)
        } ?? 60
    }
}

/// Chooses useful time labels for the current zoom level. A fixed six-hour
/// stride becomes unhelpful once only a few hours are visible.
private enum FitnessTimeAxis {
    @AxisContentBuilder
    static func marks(visibleDuration: TimeInterval) -> some AxisContent {
        if visibleDuration <= 3 * 3600 {
            marks(component: .minute, count: 30)
        } else if visibleDuration <= 8 * 3600 {
            marks(component: .hour, count: 1)
        } else if visibleDuration <= 16 * 3600 {
            marks(component: .hour, count: 3)
        } else {
            marks(component: .hour, count: 6)
        }
    }

    private static func marks(component: Calendar.Component, count: Int) -> some AxisContent {
        AxisMarks(values: .stride(by: component, count: count)) { _ in
            AxisGridLine().foregroundStyle(Theme.line)
            AxisValueLabel(format: .dateTime
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits))
                .font(Theme.mono(9))
                .foregroundStyle(Theme.sub)
        }
    }
}

private extension View {
    func fitnessChartViewport(domain: ClosedRange<Date>,
                              visibleDuration: Binding<TimeInterval>,
                              scrollPosition: Binding<Date>) -> some View {
        modifier(FitnessChartViewportModifier(domain: domain,
                                              visibleDuration: visibleDuration,
                                              scrollPosition: scrollPosition))
    }
}

/// Native chart scrolling handles one-finger horizontal movement. A UIKit
/// pinch recognizer supplies both magnification and the moving two-finger
/// centroid, which SwiftUI's scalar `MagnificationGesture` does not expose.
private struct FitnessChartViewportModifier: ViewModifier {
    let domain: ClosedRange<Date>
    @Binding var visibleDuration: TimeInterval
    @Binding var scrollPosition: Date

    @State private var gestureStartDuration: TimeInterval?
    @State private var gestureAnchorDate: Date?
    @State private var pinchActive = false

    private let minimumDuration: TimeInterval = 2 * 3600

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: domain)
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: visibleDuration)
            .chartScrollPosition(x: Binding(
                get: { scrollPosition },
                // The chart's own scroll pan may also see a two-finger touch.
                // Ignore those writes while our combined pinch is authoritative.
                set: { if !pinchActive { scrollPosition = $0 } }
            ))
            .overlay {
                ChartPinchCatcher(
                    onBegan: { fraction in beginGesture(at: fraction) },
                    onChanged: { magnification, fraction in
                        updateGesture(magnification: magnification,
                                      centroidFraction: fraction)
                    },
                    onEnded: { endGesture() }
                )
                .allowsHitTesting(false)
            }
    }

    private func beginGesture(at centroidFraction: CGFloat) {
        let fullDuration = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let duration = min(visibleDuration, fullDuration)
        gestureStartDuration = duration
        let start = clampedStart(scrollPosition, duration: duration)
        gestureAnchorDate = start.addingTimeInterval(duration * Double(centroidFraction))
        pinchActive = true
    }

    private func updateGesture(magnification: CGFloat, centroidFraction: CGFloat) {
        guard let startDuration = gestureStartDuration,
              let anchorDate = gestureAnchorDate else { return }

        let fullDuration = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let scale = max(Double(magnification), 0.01)
        let nextDuration = min(fullDuration,
                               max(minimumDuration, startDuration / scale))
        visibleDuration = nextDuration
        // Preserve the time originally under the pinch centroid. If both
        // fingers translate, the changing fraction pans the viewport too.
        scrollPosition = clampedStart(
            anchorDate.addingTimeInterval(-nextDuration * Double(centroidFraction)),
            duration: nextDuration
        )
    }

    private func endGesture() {
        gestureStartDuration = nil
        gestureAnchorDate = nil
        pinchActive = false
    }

    private func clampedStart(_ proposed: Date, duration: TimeInterval) -> Date {
        let latest = domain.upperBound.addingTimeInterval(-duration)
        return min(max(proposed, domain.lowerBound), latest)
    }
}

/// Geometry-only anchor whose pinch recognizer lives on the window. Keeping
/// the anchor out of hit-testing preserves the chart's one-finger scroll and
/// tap selection; the recognizer accepts only pinches beginning inside it.
private struct ChartPinchCatcher: UIViewRepresentable {
    let onBegan: (CGFloat) -> Void
    let onChanged: (_ magnification: CGFloat, _ centroidFraction: CGFloat) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        view.pinch = pinch
        context.coordinator.anchor = view
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        if let pinch = uiView.pinch { pinch.view?.removeGestureRecognizer(pinch) }
    }

    final class AnchorView: UIView {
        var pinch: UIPinchGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let pinch else { return }
            pinch.view?.removeGestureRecognizer(pinch)
            if let window { window.addGestureRecognizer(pinch) }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onBegan: (CGFloat) -> Void = { _ in }
        var onChanged: (CGFloat, CGFloat) -> Void = { _, _ in }
        var onEnded: () -> Void = {}
        weak var anchor: UIView?

        @objc func handlePinch(_ pinch: UIPinchGestureRecognizer) {
            switch pinch.state {
            case .began:
                onBegan(centroidFraction(of: pinch))
            case .changed:
                onChanged(pinch.scale, centroidFraction(of: pinch))
            case .ended, .cancelled, .failed:
                onEnded()
            default:
                break
            }
        }

        private func centroidFraction(of pinch: UIPinchGestureRecognizer) -> CGFloat {
            guard let anchor, anchor.bounds.width > 0 else { return 0.5 }
            let fraction = pinch.location(in: anchor).x / anchor.bounds.width
            return min(max(fraction, 0), 1)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard let anchor, anchor.window != nil else { return false }
            return anchor.bounds.contains(touch.location(in: anchor))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Let an already-tracking chart/scroll pan finish arbitration; its
            // binding writes are suppressed while the pinch is active.
            other is UIPanGestureRecognizer
        }
    }
}

/// A heart glyph in a soft red chip that pulses while live HR is active.
private struct PulsingHeart: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 15))
            .foregroundStyle(Theme.danger)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Theme.danger.opacity(0.12)))
            .scaleEffect(active && pulse ? 1.12 : 1)
            .animation(active ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                       value: pulse)
            .onAppear { pulse = active }
            .onChange(of: active) { _, on in pulse = on }
    }
}
