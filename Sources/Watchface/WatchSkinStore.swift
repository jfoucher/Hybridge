import SwiftUI

/// Optional user-supplied artwork that turns the dashboard mockup into a
/// photorealistic watch: a case image plus separate hour/minute hand images
/// that are rotated to the current time, with the live e-ink face drawn in
/// the dial. Mirrors how the official Fossil app composites its device art.
///
/// Images are looked up per slot in this order:
///   1. user import saved in Documents/watch_skin/<slot>.png
///   2. bundled Resources/watch_skin/<slot>.png (if the developer shipped one)
/// so an end user can always override, and a build can ship a default.
@MainActor
final class WatchSkinStore: ObservableObject {
    static let shared = WatchSkinStore()

    enum Slot: String, CaseIterable, Identifiable {
        case caseBody = "case"
        case hourHand = "hour_hand"
        case minuteHand = "minute_hand"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .caseBody: return String(localized: "Watch case")
            case .hourHand: return String(localized: "Hour hand")
            case .minuteHand: return String(localized: "Minute hand")
            }
        }
        var subtitle: String {
            switch self {
            case .caseBody: return String(localized: "Body with the dial centred")
            case .hourHand, .minuteHand: return String(localized: "Points to 12, pivot at image centre")
            }
        }
    }

    /// Recommended import size, shown in the UI.
    static let recommendedSize = CGSize(width: 1500, height: 2102)

    @Published private(set) var caseImage: UIImage?
    @Published private(set) var hourHandImage: UIImage?
    @Published private(set) var minuteHandImage: UIImage?

    /// The e-ink face fills ~42% of the case width, centred on the hand pivot
    /// (measured from Fossil's own art).
    let faceDiameterFraction: CGFloat = 0.5

    /// A usable skin needs at least the case; hands are optional but expected.
    var hasCase: Bool { caseImage != nil }

    /// `shared` (the Watch Appearance editor) always tracks whichever watch
    /// is active. A pinned instance stays on one watch regardless of which
    /// is active — used to render a dashboard carousel card for a watch that
    /// isn't the active one, so swiping to it shows *that* watch's own
    /// skin instead of whatever `shared` currently has loaded.
    private let pinnedWatchID: UUID?

    private init() {
        pinnedWatchID = nil
        reload()
    }

    /// A one-off loader pinned to one specific watch's on-disk skin.
    init(watchID: UUID) {
        pinnedWatchID = watchID
        reload()
    }

    private var watchID: UUID? { pinnedWatchID ?? WatchRegistry.shared.activeWatch?.id }

    func image(for slot: Slot) -> UIImage? {
        switch slot {
        case .caseBody: return caseImage
        case .hourHand: return hourHandImage
        case .minuteHand: return minuteHandImage
        }
    }

    /// True when this slot is satisfied by a user import (not the bundle).
    func isUserProvided(_ slot: Slot) -> Bool {
        FileManager.default.fileExists(atPath: documentsURL(for: slot).path)
    }

    func reload() {
        caseImage = load(.caseBody)
        hourHandImage = load(.hourHand)
        minuteHandImage = load(.minuteHand)
    }

    /// Save imported PNG data for a slot (nil clears the user import so the
    /// bundled default, if any, comes back).
    func setUserImage(_ data: Data?, for slot: Slot) {
        let url = documentsURL(for: slot)
        if let data {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            // Re-encode to PNG so we accept any picked image format.
            let png = UIImage(data: data)?.pngData() ?? data
            try? png.write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        reload()
    }

    // MARK: - Loading

    private func load(_ slot: Slot) -> UIImage? {
        let userURL = documentsURL(for: slot)
        if let image = UIImage(contentsOfFile: userURL.path) {
            return image
        }
        if let bundleURL = Bundle.main.url(forResource: slot.rawValue, withExtension: "png",
                                           subdirectory: "watch_skin"),
           let image = UIImage(contentsOfFile: bundleURL.path) {
            return image
        }
        return nil
    }

    private func documentsURL(for slot: Slot) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("watch_skin\(watchID?.uuidString ?? "")/\(slot.rawValue).png")
    }
}
