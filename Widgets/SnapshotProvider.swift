import WidgetKit
import SwiftUI

struct FossilEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Static (unconfigured) timeline: two entries from the same snapshot — one
/// "now", one at the next midnight so a widget left on screen overnight
/// rolls today's steps over to 0 without waiting for the app to relaunch.
/// Every other refresh comes from the app's own `WidgetCenter.reloadAllTimelines()`.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> FossilEntry {
        FossilEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (FossilEntry) -> Void) {
        let snapshot = context.isPreview ? .preview : WidgetStore.load()
        completion(FossilEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FossilEntry>) -> Void) {
        let snapshot = WidgetStore.load()
        let start = Calendar.current.startOfDay(for: .now)
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86400)
        let entries = [
            FossilEntry(date: .now, snapshot: snapshot),
            FossilEntry(date: midnight, snapshot: snapshot),
        ]
        completion(Timeline(entries: entries, policy: .after(midnight)))
    }
}

extension WidgetSnapshot {
    static var preview: WidgetSnapshot {
        WidgetSnapshot(updatedAt: .now, watchName: "Gen 6 Hybrid", hasDisplay: true,
                       todaySteps: 6842, stepsDate: .now, stepsAreLive: true,
                       stepGoal: 10000, batteryPercent: 76, batteryDate: .now,
                       isConnected: true, lastSyncDate: .now.addingTimeInterval(-1800))
    }
}

/// Shown for every widget kind when nothing has been synced into the app
/// group yet (fresh install, or the entitlement failed to register).
struct SetupView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "applewatch")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Hybridge to set up")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

func compactNumber(_ value: Int) -> String {
    value.formatted(.number)
}

func compactShortNumber(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName))
}

/// SF Symbol name for a battery percentage — Apple ships exactly these five
/// discrete `battery.*` glyphs.
func batterySymbol(_ percent: Int) -> String {
    switch percent {
    case ..<13: return "battery.0"
    case ..<38: return "battery.25"
    case ..<63: return "battery.50"
    case ..<88: return "battery.75"
    default: return "battery.100"
    }
}
