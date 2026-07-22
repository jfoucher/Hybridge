import SwiftUI
import Charts

/// Trends over the synced history: resting heart rate, daily steps vs goal,
/// and streaks — the "wellness" half of the official app.
struct WellnessView: View {
    @ObservedObject private var fitness = FitnessStore.shared
    @AppStorage("stepGoal") private var stepGoal = 10000
    @State private var rangeDays = 14

    private var summaries: [FitnessStore.DaySummary] {
        fitness.dailySummaries(days: rangeDays)
    }

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $rangeDays) {
                    Text("2 weeks").tag(14)
                    Text("Month").tag(30)
                    Text("3 months").tag(90)
                }
                .pickerStyle(.segmented)
            }

            statsSection
            stepsSection
            restingHRSection
        }
        .navigationTitle("Wellness")
        .themedList()
    }

    // MARK: Headline numbers

    private var statsSection: some View {
        Section {
            HStack {
                statTile(value: "\(fitness.stepGoalStreak(goal: stepGoal))",
                         unit: "days", label: "Goal streak")
                Divider()
                statTile(value: weeklyAverageSteps.formatted(),
                         unit: "steps", label: "Daily avg (7 d)")
                Divider()
                statTile(value: latestRestingHR?.formatted() ?? "–",
                         unit: "bpm", label: "Resting HR")
            }
        }
    }

    private var weeklyAverageSteps: Int {
        let week = fitness.dailySummaries(days: 7)
        guard !week.isEmpty else { return 0 }
        return week.reduce(0) { $0 + $1.steps } / week.count
    }

    private var latestRestingHR: Int? {
        summaries.reversed().compactMap(\.restingHR).first
    }

    private func statTile(value: String, unit: LocalizedStringResource,
                          label: LocalizedStringResource) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(unit).font(.caption2).foregroundStyle(.secondary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Charts

    private var stepsSection: some View {
        Section("Steps per day") {
            let data = summaries
            if data.allSatisfy({ $0.steps == 0 }) {
                Text("No activity data in this range yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(data) { day in
                        BarMark(x: .value("Day", day.day, unit: .day),
                                y: .value("Steps", day.steps))
                            .foregroundStyle(.teal)
                            .cornerRadius(2)
                    }
                    RuleMark(y: .value("Goal", stepGoal))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .topTrailing) {
                            Text("goal").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .frame(height: 160)
            }
        }
    }

    private var restingHRSection: some View {
        Section {
            let points = summaries.filter { $0.restingHR != nil }
            if points.count < 2 {
                Text("Not enough overnight heart-rate data yet — resting HR needs a few days of history.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart(points) { day in
                    LineMark(x: .value("Day", day.day, unit: .day),
                             y: .value("bpm", day.restingHR ?? 0))
                        .foregroundStyle(.pink)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Day", day.day, unit: .day),
                              y: .value("bpm", day.restingHR ?? 0))
                        .foregroundStyle(.pink)
                        .symbolSize(24)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxisLabel("bpm")
                .frame(height: 160)
            }
        } header: {
            Text("Resting heart rate")
        } footer: {
            Text("The calmest 5% of heart-rate readings while inactive, per day.")
        }
    }
}
