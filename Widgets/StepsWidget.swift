import WidgetKit
import SwiftUI

struct StepsWidget: Widget {
    let kind = "eu.sixpixels.hybridge.steps"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            StepsWidgetView(entry: entry)
        }
        .configurationDisplayName("Steps")
        .description("Today's step count from your watch.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

private struct StepsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FossilEntry

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryCircular:
                circular(snapshot)
            default:
                small(snapshot)
            }
        } else {
            SetupView()
        }
    }

    private func circular(_ snapshot: WidgetSnapshot) -> some View {
        let steps = snapshot.stepsForDisplay(at: entry.date) ?? 0
        let goal = max(snapshot.stepGoal, 1)
        return Gauge(value: Double(min(steps, goal)), in: 0...Double(goal)) {
            Image(systemName: "figure.walk")
        } currentValueLabel: {
            Text(compactShortNumber(steps))
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        let steps = snapshot.stepsForDisplay(at: entry.date)
        let progress = Double(steps ?? 0) / Double(max(snapshot.stepGoal, 1))
        let done = progress >= 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "figure.walk")
                    .foregroundStyle(.orange)
                Spacer()
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            Text(steps.map(compactNumber) ?? "0")
                .font(.title2.bold())
            Text("of \(compactNumber(snapshot.stepGoal)) steps")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ProgressView(value: min(progress, 1))
                .tint(done ? .green : .orange)
            footer(snapshot, steps: steps)
        }
    }

    @ViewBuilder
    private func footer(_ snapshot: WidgetSnapshot, steps: Int?) -> some View {
        if steps == nil {
            Text("Not synced today")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if !snapshot.stepsAreLive, let lastSync = snapshot.lastSyncDate {
            Text("As of \(lastSync, style: .time)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
