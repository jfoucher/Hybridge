import Foundation
import UIKit

/// Which iOS apps get which icon on the watch's notification screen.
///
/// iOS offers no way to enumerate installed apps or read their artwork, so
/// icons are SF Symbols rendered to 24×24 and matched to notifications by
/// CRC32 of the bundle ID (the ANCS app identifier the watch sees once
/// bonded). Ships a curated default set; users can add their own bundle IDs.
@MainActor
final class NotificationIconStore: ObservableObject {
    static let shared = NotificationIconStore()

    struct Entry: Codable, Identifiable, Equatable {
        var bundleId: String
        var displayName: String
        var symbol: String
        var enabled = true

        var id: String { bundleId }
        /// Asset name on the watch. GB shortens package names the same way to
        /// keep the icon file small.
        var iconName: String {
            (bundleId.split(separator: ".").last.map(String.init) ?? bundleId) + ".icon"
        }
    }

    static let defaults: [Entry] = [
        Entry(bundleId: "com.apple.MobileSMS", displayName: String(localized: "Messages"), symbol: "message.fill"),
        Entry(bundleId: "com.apple.mobilemail", displayName: String(localized: "Mail"), symbol: "envelope.fill"),
        Entry(bundleId: "com.apple.mobilecal", displayName: String(localized: "Calendar"), symbol: "calendar"),
        Entry(bundleId: "com.apple.facetime", displayName: "FaceTime", symbol: "video.fill"),
        Entry(bundleId: "com.apple.reminders", displayName: String(localized: "Reminders"), symbol: "checklist"),
        Entry(bundleId: "net.whatsapp.WhatsApp", displayName: "WhatsApp", symbol: "phone.bubble.fill"),
        Entry(bundleId: "ph.telegra.Telegraph", displayName: "Telegram", symbol: "paperplane.fill"),
        Entry(bundleId: "org.whispersystems.signal", displayName: "Signal", symbol: "bubble.left.fill"),
        Entry(bundleId: "com.google.Gmail", displayName: "Gmail", symbol: "envelope.open.fill"),
        Entry(bundleId: "com.microsoft.Office.Outlook", displayName: "Outlook", symbol: "envelope.circle.fill"),
        Entry(bundleId: "com.facebook.Messenger", displayName: "Messenger", symbol: "bubble.left.and.bubble.right.fill"),
        Entry(bundleId: "com.burbn.instagram", displayName: "Instagram", symbol: "camera.fill"),
        Entry(bundleId: "com.tinyspeck.chatlyio", displayName: "Slack", symbol: "number.square.fill"),
        Entry(bundleId: "com.linkedin.LinkedIn", displayName: "LinkedIn", symbol: "briefcase.fill"),
    ]

    // Shared by every compatible watch; each receives this icon set on connect.
    private let entriesKey = WatchScopedKey.notificationIconEntries.rawValue
    private let enabledKey = WatchScopedKey.notificationIconsEnabled.rawValue
    private let allAppsKey = WatchScopedKey.notificationAllApps.rawValue

    @Published var entries: [Entry] {
        didSet { persist() }
    }

    @Published var isEnabled: Bool {
        didSet {
            guard !isReloading else { return }
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
        }
    }

    /// Adds catch-all filter entries so every app's notification shows (with
    /// the generic icon), like the official app's "all apps" mode.
    @Published var allowAllApps: Bool {
        didSet {
            guard !isReloading else { return }
            UserDefaults.standard.set(allowAllApps, forKey: allAppsKey)
        }
    }

    /// Set while loading persisted values, so the
    /// didSet persistence doesn't write them straight back.
    private var isReloading = false

    private init() {
        entries = []
        isEnabled = true
        allowAllApps = false
        reload()
    }

    private func reload() {
        isReloading = true
        defer { isReloading = false }
        if let data = UserDefaults.standard.data(forKey: entriesKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = stored
        } else {
            entries = Self.defaults
        }
        isEnabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        allowAllApps = UserDefaults.standard.object(forKey: allAppsKey) as? Bool ?? false
    }

    private func persist() {
        guard !isReloading else { return }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }

    // MARK: Watch payloads

    /// Everything for the 0x0701 icon file: the four GB default icons plus
    /// one per enabled app entry.
    func iconAssets() -> [WatchNotificationIcon] {
        var icons: [WatchNotificationIcon] = []
        func add(_ name: String, symbol: String) {
            if let icon = Self.renderIcon(named: name, symbol: symbol) {
                icons.append(icon)
            }
        }
        // Same default set GB uploads (names are firmware-known).
        add("icIncomingCall.icon", symbol: "phone.fill")
        add("icMissedCall.icon", symbol: "phone.down.fill")
        add("icMessage.icon", symbol: "message.fill")
        add("general_white.bin", symbol: "app.badge.fill")
        for entry in entries where entry.enabled {
            add(entry.iconName, symbol: entry.symbol)
        }
        return icons
    }

    /// Everything for the 0x0C00 filter file: generic + call (GB layout,
    /// serving the app's own play path), then per-app entries keyed by
    /// CRC32(bundle id + NUL) — the firmware's ANCS hash. Enabled apps get
    /// their icon, disabled apps an explicit block entry (only meaningful
    /// with the catch-all present, but emitted unconditionally so a listed
    /// app's switch always means the same thing), and with All apps on the
    /// catch-all lets everything else through with the generic icon.
    func filters() -> [AppNotificationFilter] {
        var filters: [AppNotificationFilter] = [.generic(), .call]
        for entry in entries {
            if entry.enabled {
                filters.append(.app(bundleId: entry.bundleId, iconName: entry.iconName))
            } else {
                filters.append(.blocked(bundleId: entry.bundleId))
            }
        }
        if allowAllApps {
            filters.append(.catchAll())
        }
        return filters
    }

    /// Renders an SF Symbol as a white 24×24 template on transparency — the
    /// notification banner on the watch is dark, matching GB's white icons.
    static func renderIcon(named name: String, symbol: String) -> WatchNotificationIcon? {
        let side = WatchNotificationIcon.maxSide
        let config = UIImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.8,
                                                 weight: .regular)
        guard let symbolImage = UIImage(systemName: symbol, withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let canvas = CGSize(width: side, height: side)
        let rendered = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            // Fit the (usually non-square) symbol centered in the canvas.
            let size = symbolImage.size
            let scale = min(CGFloat(side) / size.width, CGFloat(side) / size.height, 1)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            symbolImage.draw(in: CGRect(x: (canvas.width - fitted.width) / 2,
                                        y: (canvas.height - fitted.height) / 2,
                                        width: fitted.width, height: fitted.height))
        }
        guard let pixels = ImageEncoder.pixels(from: rendered, width: side, height: side) else {
            return nil
        }
        let rle = ImageEncoder.rleEncode(ImageEncoder.rlePixelBytes(from: pixels))
        return WatchNotificationIcon(name: name, width: side, height: side, rleData: rle)
    }
}
