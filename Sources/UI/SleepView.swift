import SwiftUI
import Charts

/// Nightly sleep: duration trend, per-night session timeline and a
/// restfulness breakdown. All inferred — the watch stores no sleep data.
struct SleepView: View {
    @ObservedObject private var fitness = FitnessStore.shared
    @State private var selectedNight = Date()
    @State private var chartSelection: Date?

    private static let nightCount = 14

    private struct Night: Identifiable {
        var day: Date
        var seconds: Int
        var id: Date { day }
    }

    private var nights: [Night] {
        (0..<Self.nightCount).reversed().compactMap { back in
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: Date()) else { return nil }
            return Night(day: Calendar.current.startOfDay(for: day),
                         seconds: fitness.sleepDuration(nightEnding: day))
        }
    }

    var body: some View {
        List {
            Section {
                let data = nights
                if data.allSatisfy({ $0.seconds == 0 }) {
                    Text("No sleep detected in the last \(Self.nightCount) nights. Wear the watch overnight and sync in the morning.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Chart(data) { night in
                        BarMark(x: .value("Night", night.day, unit: .day),
                                y: .value("Hours", Double(night.seconds) / 3600))
                            .foregroundStyle(.indigo)
                            .cornerRadius(3)
                    }
                    .chartYAxisLabel("hours")
                    .frame(height: 160)
                    .chartXSelection(value: $chartSelection)
                    .onChange(of: chartSelection) { _, newValue in
                        if let newValue { selectedNight = newValue }
                    }
                }
            } header: {
                Text("Last \(Self.nightCount) nights")
            } footer: {
                Text("Tap a bar to inspect that night below.")
            }

            Section {
                DatePicker("Night ending", selection: $selectedNight, displayedComponents: .date)
                let sessions = fitness.sleepSessions(nightEnding: selectedNight)
                if sessions.isEmpty {
                    Text("No sleep detected for this night.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    let total = sessions.reduce(0) { $0 + $1.duration }
                    LabeledContent("Total") {
                        Text("\(total / 3600) h \((total % 3600) / 60) min")
                    }
                    sessionTimeline(sessions)
                    ForEach(sessions) { session in
                        sessionRow(session)
                    }
                }
            } header: {
                Text("Night detail")
            } footer: {
                Text("Sleep is inferred from long still stretches while worn and with a low heart rate — so quiet time at a desk isn't mistaken for sleep. \"Restful\" marks the calmest third of each session by movement variability — a rough guide, not a medical measure.")
            }
        }
        .navigationTitle("Sleep")
        .themedList()
    }

    private struct PhasePoint: Identifiable {
        var date: Date
        var isDeep: Bool
        var id: Date { date }
    }

    private func sessionTimeline(_ sessions: [FitnessStore.SleepSession]) -> some View {
        let points = sessions.flatMap { session in
            fitness.sleepPhases(for: session).map { PhasePoint(date: $0.date, isDeep: $0.isDeep) }
        }
        let restful = String(localized: "Restful")
        let light = String(localized: "Light")
        // One hue, two lightness steps: restful (deep) vs lighter sleep.
        return Chart(points) { phase in
            BarMark(xStart: .value("Start", phase.date),
                    xEnd: .value("End", phase.date.addingTimeInterval(60)),
                    y: .value("Night", "sleep"))
                .foregroundStyle(by: .value("Phase", phase.isDeep ? restful : light))
        }
        .chartForegroundStyleScale([restful: Color.indigo, light: Color.indigo.opacity(0.35)])
        .chartYAxis(.hidden)
        .chartLegend(position: .bottom)
        .frame(height: 64)
    }

    private func sessionRow(_ session: FitnessStore.SleepSession) -> some View {
        LabeledContent {
            Text("\(session.duration / 60) min")
        } label: {
            Text("\(Date(timeIntervalSince1970: TimeInterval(session.startTimestamp)), format: .dateTime.hour().minute()) – \(Date(timeIntervalSince1970: TimeInterval(session.endTimestamp)), format: .dateTime.hour().minute())")
        }
        .font(.footnote)
    }
}
