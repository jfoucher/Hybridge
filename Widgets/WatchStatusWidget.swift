import WidgetKit
import SwiftUI

struct WatchStatusWidget: Widget {
    let kind = "eu.sixpixels.hybridge.status"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            WatchStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Watch Status")
        .description("Connection, battery and last sync for your watch.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

private struct WatchStatusWidgetView: View {
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
            case .accessoryInline:
                inline(snapshot)
            case .accessoryRectangular:
                rectangular(snapshot)
            case .systemMedium:
                medium(snapshot)
            default:
                small(snapshot)
            }
        } else {
            SetupView()
        }
    }

    /// `applewatch` for the e-ink HR, `clock` for the hands-only Q — icon
    /// choice mirrors WatchKind.hasDisplay elsewhere in the app.
    private func icon(_ snapshot: WidgetSnapshot) -> String {
        snapshot.hasDisplay ? "applewatch" : "clock"
    }

    private func connectionText(_ snapshot: WidgetSnapshot) -> Text {
        switch snapshot.connectionForDisplay(at: entry.date) {
        case .some(true): return Text("Connected")
        case .some(false): return Text("Not connected")
        case .none: return Text("Last seen \(snapshot.updatedAt, style: .relative)")
        }
    }

    @ViewBuilder
    private func batteryLine(_ snapshot: WidgetSnapshot) -> some View {
        if let battery = snapshot.batteryForDisplay(at: entry.date) {
            Image(systemName: batterySymbol(battery.percent))
            Text("\(battery.percent)%")
        } else {
            Image(systemName: "battery.0")
            Text("—")
        }
    }

    private func inline(_ snapshot: WidgetSnapshot) -> some View {
        let battery = snapshot.batteryForDisplay(at: entry.date)
        let steps = snapshot.stepsForDisplay(at: entry.date)
        return Label {
            Text("\(battery.map { "\($0.percent)%" } ?? "—") · \(compactShortNumber(steps ?? 0)) steps")
        } icon: {
            Image(systemName: icon(snapshot))
        }
    }

    private func rectangular(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(snapshot.watchName ?? String(localized: "Watch"), systemImage: icon(snapshot))
                .font(.headline)
                .lineLimit(1)
            connectionText(snapshot)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                batteryLine(snapshot)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon(snapshot))
                Text(snapshot.watchName ?? String(localized: "Watch"))
                    .font(.headline)
                    .lineLimit(1)
            }
            connectionText(snapshot)
                .font(.subheadline)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                batteryLine(snapshot)
            }
            .font(.caption)
            lastSyncLine(snapshot)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            small(snapshot)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let steps = snapshot.stepsForDisplay(at: entry.date) {
                    Text(compactNumber(steps))
                        .font(.title2.bold())
                } else {
                    Text("Not synced today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func lastSyncLine(_ snapshot: WidgetSnapshot) -> Text {
        guard let lastSync = snapshot.lastSyncDate else { return Text("Never synced") }
        return Text("Synced \(lastSync, style: .relative)")
    }
}
