import SwiftUI
import Charts

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
        }
    }

    // MARK: Layout helpers

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
                    let bars = fitness.stepsPerHour(from: window.lowerBound, to: window.upperBound)
                        .map { HourBar(date: $0.date, steps: $0.steps) }
                    if bars.allSatisfy({ $0.steps == 0 }) {
                        Text("No step data for this period.")
                            .font(Theme.sans(13, relativeTo: .footnote)).foregroundStyle(Theme.sub)
                            .frame(height: 104, alignment: .center)
                            .frame(maxWidth: .infinity)
                    } else {
                        StepsChartView(bars: bars, domain: window)
                    }
                }
                .padding(16)
            }
            Footer("Today's total is read from the watch's step counter. The hourly breakdown is reconstructed from synced minute samples and may not add up.")
        }
    }

    // MARK: Heart rate card

    private var heartRateCard: some View {
        let window = chartWindow
        let series = fitness.heartRateSeries(from: window.lowerBound, to: window.upperBound)
        return ThemedCard {
            VStack(alignment: .leading, spacing: 10) {
                if series.isEmpty {
                    Text("No heart-rate data for this period.")
                        .font(Theme.sans(13, relativeTo: .footnote)).foregroundStyle(Theme.sub)
                        .frame(height: 96, alignment: .center).frame(maxWidth: .infinity)
                } else {
                    let bpms = series.map(\.bpm)
                    Text("\(bpms.min() ?? 0)–\(bpms.max() ?? 0) bpm")
                        .font(Theme.mono(13))
                        .foregroundColor(Theme.sub)
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
                    .chartXScale(domain: window)
                    .chartYScale(domain: 40...180)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                            AxisGridLine().foregroundStyle(Theme.line)
                            AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                                .font(Theme.mono(9)).foregroundStyle(Theme.sub)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [40, 80, 120, 160]) { _ in
                            AxisGridLine().foregroundStyle(Theme.line)
                            AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.sub)
                        }
                    }
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
            NavigationLink { WellnessView() } label: {
                wellnessRow("Workouts", value: workoutsThisWeek, chevron: true, valueMuted: true)
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
private struct HourBar: Identifiable { let date: Date; let steps: Int; var id: Date { date } }
private struct HRPoint: Identifiable { let date: Date; let bpm: Int; var id: Date { date } }

/// The steps bar chart: real clock hours on the x axis, step-count
/// graduations on the y axis, and tap-to-highlight with a value tooltip.
private struct StepsChartView: View {
    let bars: [HourBar]
    let domain: ClosedRange<Date>
    @State private var selectedDate: Date?

    private var maxSteps: Int { max(bars.map(\.steps).max() ?? 1, 1) }

    private var selected: HourBar? {
        guard let selectedDate else { return nil }
        return bars.first { selectedDate >= $0.date && selectedDate < $0.date.addingTimeInterval(3600) }
    }

    var body: some View {
        Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Time", bar.date), y: .value("Steps", bar.steps), width: .fixed(9))
                    .foregroundStyle(barColor(bar.steps))
                    .cornerRadius(3)
                    .opacity(selected == nil || selected?.date == bar.date ? 1 : 0.35)
            }
            if let selected {
                RuleMark(x: .value("Time", selected.date))
                    .foregroundStyle(Theme.sub.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .annotation(position: .top, spacing: 4) {
                        tooltip(for: selected)
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(Theme.mono(9)).foregroundStyle(Theme.sub)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel().font(Theme.mono(9)).foregroundStyle(Theme.sub)
            }
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: 120)
    }

    private func barColor(_ steps: Int) -> Color {
        let f = Double(steps) / Double(maxSteps)
        if f >= 0.55 { return Theme.accent }
        if f >= 0.25 { return Theme.barMid }
        return Theme.barLow
    }

    private func tooltip(for bar: HourBar) -> some View {
        let end = Calendar.current.date(byAdding: .hour, value: 1, to: bar.date) ?? bar.date
        let startText = bar.date.formatted(date: .omitted, time: .shortened)
        let endText = end.formatted(date: .omitted, time: .shortened)
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
