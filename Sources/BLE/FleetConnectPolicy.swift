import Foundation

/// Pure decision for which roster watches the fleet should maintain a live
/// connection to. Kept free of CoreBluetooth so it is exhaustively unit
/// testable without a `CBCentralManager`.
///
/// A watch is connected unless it is explicitly parked (`keepConnected ==
/// false`). `nil` (older rosters, freshly added watches) means "yes".
enum FleetConnectPolicy {
    /// The watch ids the fleet should keep a pending connect for.
    static func watchesToConnect(roster: [KnownWatch]) -> [UUID] {
        roster.filter { $0.keepConnected != false }.map(\.id)
    }

    /// Whether `id` should be (re)connected — true unless it was forgotten
    /// (absent from the roster) or explicitly parked.
    static func shouldStayConnected(_ id: UUID, roster: [KnownWatch]) -> Bool {
        guard let watch = roster.first(where: { $0.id == id }) else { return false }
        return watch.keepConnected != false
    }

    /// A restored pending connect for `id` should be adopted only if the watch
    /// is one we want connected; otherwise iOS's pending connect is a stray to
    /// cancel (a forgotten or parked watch).
    static func shouldAdoptRestored(_ id: UUID, roster: [KnownWatch]) -> Bool {
        shouldStayConnected(id, roster: roster)
    }
}
