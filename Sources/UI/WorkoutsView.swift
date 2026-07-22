import SwiftUI

/// The synced workout sessions parsed from the watch's activity files, most
/// recent first, with per-session distance / calories / heart-rate detail.
struct WorkoutsView: View {
    @ObservedObject private var fitness = FitnessStore.shared

    private var workouts: [WorkoutSummary] {
        fitness.workouts.sorted { $0.startTimestamp > $1.startTimestamp }
    }

    var body: some View {
        List {
            if workouts.isEmpty {
                Section {
                    Text("No workouts yet. Start a workout from the watch and sync — recorded sessions show up here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ForEach(workouts) { workout in
                    Section {
                        workoutHeader(workout)
                        statsRows(workout)
                    }
                }
            }
        }
        .navigationTitle("Workouts")
        .themedList()
    }

    private func workoutHeader(_ workout: WorkoutSummary) -> some View {
        let start = Date(timeIntervalSince1970: TimeInterval(workout.startTimestamp))
        return HStack(spacing: 12) {
            Image(systemName: Self.symbol(for: workout.kind))
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.displayName(for: workout.kind))
                    .font(.headline)
                Text(start.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.durationText(workout.endTimestamp - workout.startTimestamp))
                .font(.title3.monospacedDigit())
        }
    }

    @ViewBuilder
    private func statsRows(_ workout: WorkoutSummary) -> some View {
        if let distance = workout.distanceMeters, distance > 0 {
            LabeledContent("Distance") { Text(Self.distanceText(distance)) }
        }
        if let calories = workout.calories, calories > 0 {
            LabeledContent("Calories") { Text("\(calories) kcal") }
        }
        if let steps = workout.steps, steps > 0 {
            LabeledContent("Steps") { Text(steps.formatted()) }
        }
        if let avg = workout.averageHeartRate, avg > 0 {
            LabeledContent("Avg heart rate") { Text("\(avg) bpm") }
        }
        if let max = workout.maxHeartRate, max > 0 {
            LabeledContent("Max heart rate") { Text("\(max) bpm") }
        }
    }

    // MARK: Display helpers

    private static func durationText(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return String(localized: "\(h) h \(m) min") }
        return String(localized: "\(m) min")
    }

    private static func distanceText(_ meters: Int) -> String {
        Measurement(value: Double(meters), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated,
                                    usage: .road,
                                    numberFormatStyle: .number.precision(.fractionLength(0...2))))
    }

    private static func displayName(for kind: String) -> String {
        kind == "Activity" ? String(localized: "Workout") : kind
    }

    private static func symbol(for kind: String) -> String {
        switch kind {
        case "Running", "Treadmill": return "figure.run"
        case "Cycling", "Spinning": return "figure.outdoor.cycle"
        case "Cross trainer": return "figure.elliptical"
        case "Weightlifting": return "dumbbell.fill"
        case "Training": return "figure.strengthtraining.functional"
        case "Walking": return "figure.walk"
        case "Rowing machine": return "figure.rower"
        case "Hiking": return "figure.hiking"
        default: return "figure.mixed.cardio"
        }
    }
}
