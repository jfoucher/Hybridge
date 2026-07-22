import Foundation

/// One-time data migrations. Runs before the CoreBluetooth central is
/// created (and before the registry loads), so every settings read sees the
/// current ownership model.
enum AppMigrations {
    static let versionKey = "multiWatchMigrationVersion"
    /// Consumed by FitnessStore on its next load: tags the pre-multi-watch
    /// archive with the first watch's id.
    static let fitnessLegacyOwnerKey = "fitnessLegacyOwner"

    static func run(defaults: UserDefaults = .standard) {
        if defaults.integer(forKey: versionKey) < 1 {
            migrateSingleWatchRoster(defaults: defaults)
            defaults.set(1, forKey: versionKey)
        }
        if defaults.integer(forKey: versionKey) < 2 {
            migrateSharedSettings(defaults: defaults)
            defaults.set(2, forKey: versionKey)
        }
    }

    /// v0 → v1: adopt the single remembered watch as the first roster entry
    /// and move its keychain key and then-per-watch settings into its namespace.
    private static func migrateSingleWatchRoster(defaults: UserDefaults) {
        // rememberedPeripheralID itself is left behind as a downgrade net —
        // nothing reads it anymore.
        guard let idString = defaults.string(forKey: "rememberedPeripheralID"),
              let id = UUID(uuidString: idString) else { return }

        let watch = KnownWatch(id: id, name: String(localized: "My watch"), modelNumber: nil,
                               addedDate: Date(), lastConnectedDate: nil,
                               kind: nil, firmware: nil, trusted: true)
        if let data = try? JSONEncoder().encode([watch]) {
            defaults.set(data, forKey: WatchRegistry.watchesKey)
        }
        defaults.set(id.uuidString, forKey: WatchRegistry.activeKey)

        if let key = KeychainStore.loadLegacyKey() {
            KeychainStore.saveKey(key, for: id)
            KeychainStore.deleteLegacyKey()
        }

        for base in WatchScoped.perWatchKeys {
            if let value = defaults.object(forKey: base) {
                defaults.set(value, forKey: WatchScoped.key(base, watchID: id))
                defaults.removeObject(forKey: base)
            }
        }
        // The removed commute feature's legacy key is cleared if still present.
        defaults.removeObject(forKey: "commuteDestinations")
        defaults.set(id.uuidString, forKey: fitnessLegacyOwnerKey)
    }

    /// v1 → v2: settings reachable from the Settings tab became global.
    /// Preserve the active watch's values as the shared preference; legacy
    /// scoped copies remain harmless and are still removed when a watch is
    /// forgotten.
    private static func migrateSharedSettings(defaults: UserDefaults) {
        let activeID = defaults.string(forKey: WatchRegistry.activeKey).flatMap(UUID.init)
        guard let activeID else { return }

        let sharedKeys: [WatchScopedKey] = [
            .vibrationStrength,
            .bodyHeightCm, .bodyWeightKg, .bodyGender, .bodyBirth,
            .buttonSelections,
            .notificationIconEntries, .notificationIconsEnabled, .notificationAllApps,
            .qNotificationAlerts, .qButtonFunctions, .qMultiPressActions,
            .quietSchedule, .quietOverride,
        ]
        for key in sharedKeys where defaults.object(forKey: key.rawValue) == nil {
            let oldKey = WatchScoped.key(key, watchID: activeID)
            if let value = defaults.object(forKey: oldKey) {
                defaults.set(value, forKey: key.rawValue)
            }
        }
    }
}
