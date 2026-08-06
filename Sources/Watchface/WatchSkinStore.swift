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

    /// The in-flight `reload()`, cancelled and replaced by the next one so a
    /// slow load from a stale call (e.g. superseded by a fast watch switch)
    /// can never land after — and clobber — a newer one's result.
    private var loadTask: Task<Void, Never>?

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

    /// Re-reads every slot from disk. The actual file reads and PNG decodes
    /// (up to three full-resolution images, `recommendedSize` 1500×2102) run
    /// off the main actor — this used to decode synchronously right here,
    /// which is cheap for one store but not for `WatchCarousel` re-creating a
    /// pinned store per non-active roster watch every time the Watch tab is
    /// revisited (the custom tab container tears down and rebuilds the
    /// inactive tab's view state on every switch, so this ran on every
    /// visit, not just the first): with a couple of registered watches and
    /// custom skins, that was blocking the main thread for the whole
    /// three-image decode, i.e. exactly the multi-second freeze on tab
    /// change this was tracked down from.
    func reload() {
        loadTask?.cancel()
        let caseCandidates = resolvedPaths(for: .caseBody)
        let hourCandidates = resolvedPaths(for: .hourHand)
        let minuteCandidates = resolvedPaths(for: .minuteHand)
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let loadedCase = Self.firstImage(in: caseCandidates)
            let loadedHour = Self.firstImage(in: hourCandidates)
            let loadedMinute = Self.firstImage(in: minuteCandidates)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.caseImage = loadedCase
                self.hourHandImage = loadedHour
                self.minuteHandImage = loadedMinute
            }
        }
    }

    /// First path in `candidates` (preference order) that decodes as an
    /// image. `nonisolated` so it runs on the detached task's own thread
    /// rather than hopping to the main actor per call.
    nonisolated private static func firstImage(in candidates: [String]) -> UIImage? {
        for path in candidates {
            if let image = UIImage(contentsOfFile: path) { return image }
        }
        return nil
    }

    /// Save imported PNG data for a slot (nil clears the user import so the
    /// bundled default, if any, comes back).
    @discardableResult
    func setUserImage(_ data: Data?, for slot: Slot) async -> Bool {
        let url = documentsURL(for: slot)
        let succeeded = await Task.detached(priority: .utility) {
            Self.persist(data, to: url)
        }.value
        if !succeeded {
            NSLog("WatchSkinStore: update failed for \(slot.rawValue)")
        }
        reload()
        return succeeded
    }

    nonisolated private static func persist(_ data: Data?, to url: URL) -> Bool {
        do {
            if let data {
                guard data.count <= Int(BoundedPhotoTransfer.maximumCompressedBytes),
                      UIImage(data: data) != nil else { return false }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                guard try Data(contentsOf: url) == data else { return false }
                var mutableURL = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? mutableURL.setResourceValues(values)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            NSLog("WatchSkinStore: persistence failed: \(error)")
            return false
        }
    }

    // MARK: - Loading

    /// Candidate file paths for a slot, most-preferred first — user import,
    /// then bundled default. Pure path/URL lookup, no disk I/O, so it's cheap
    /// to resolve on the main actor before handing the list to the
    /// background task that does the actual reading.
    private func resolvedPaths(for slot: Slot) -> [String] {
        var paths = [documentsURL(for: slot).path]
        if let bundleURL = Bundle.main.url(forResource: slot.rawValue, withExtension: "png",
                                           subdirectory: "watch_skin") {
            paths.append(bundleURL.path)
        }
        return paths
    }

    private func documentsURL(for slot: Slot) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("watch_skin\(watchID?.uuidString ?? "")/\(slot.rawValue).png")
    }
}
