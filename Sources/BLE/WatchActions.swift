import Foundation
import CoreBluetooth
import UIKit

/// High-level watch operations, composed from serialized protocol requests.
extension WatchManager {
    /// Debug file-manager mutation still obeys the same token-bound session
    /// invariant as production operations.
    func deleteFileForDebug(handle: UInt16) async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await self.run(FileDeleteRequest(handle: handle))
        }
    }

    /// Shared with initializeQWatch (QWatchActions.swift): true while either
    /// family's init sequence is running.
    ///
    /// Mutual exclusion is `WatchSession.exclusive`'s job — this is only a
    /// status flag, so that callers which merely want to *avoid* piling onto
    /// a running init (`waitUntilIdle`, `periodicMaintenance`) can check
    /// cheaply without taking the session. It is read from bleQueue, main and
    /// arbitrary task executors, so it is lock-guarded rather than a bare
    /// `static var`.
    static var initInProgress: Bool {
        get { initFlagLock.withLock { initInProgressStorage } }
        set { initFlagLock.withLock { initInProgressStorage = newValue } }
    }
    private static let initFlagLock = NSLock()
    nonisolated(unsafe) private static var initInProgressStorage = false

    /// The auth key of the active watch — every protocol operation that
    /// needs the key runs against the watch the session belongs to.
    private func activeWatchKey() throws -> Data {
        guard let token = WatchSession.connectionToken ?? connectionTokenSync(),
              validatesConnectionToken(token),
              let key = KeychainStore.loadKey(for: token.watchID) else {
            throw FossilError.missingAuthKey
        }
        return key
    }

    /// Full app-level init after BLE characteristics are ready:
    /// device info (file versions) → authenticate → set time → list apps.
    func initializeWatch() async {
        // Taking the session waits out anything already talking to the watch
        // — including a previous watch's init still unwinding after a switch,
        // which is what the old spin-then-check did, minus that check's
        // check-then-act hole (two inits could both observe the flag clear
        // across the sleep and proceed).
        try? await WatchSession.exclusive(for: connectionTokenSync()) {
            Self.initInProgress = true
            defer { Self.initInProgress = false }
            await initializeWatchLocked()
        }
    }

    /// The init sequence proper. Runs with the session held.
    private func initializeWatchLocked() async {
        // Bail out if the user switches watches mid-init: a slow init must
        // not send requests to, or publish state for, the wrong watch.
        guard let token = WatchSession.connectionToken else { return }
        func stillActive() -> Bool { validatesConnectionToken(token) }
        do {
            try await fetchDeviceInfo()
            try await authenticate()
            guard stillActive() else { return }
            if adoptingNewWatch {
                // Trust gate first: the freshly added watch buzzes and the
                // user must press a button before we bond, so a stranger's
                // nearby watch can't be added by accident. Not confirmed →
                // undo the add entirely.
                guard await confirmAdoption() else {
                    adoptingNewWatch = false
                    autoPairOnNextInit = false
                    await abandonAdoption(token.watchID)
                    return
                }
                adoptingNewWatch = false
                guard stillActive() else { return }
            }
            if let paired = try? await checkDevicePairing(),
               !paired, autoPairOnNextInit {
                // Freshly added watch: bring up the iOS pairing dialog right
                // away, like the official app does on first connect.
                try? await performDevicePairing()
            }
            autoPairOnNextInit = false
            try? await setTime()
            if let config = try? await readConfiguration() {
                try? await reapplyDeviceSettingsIfNeeded(config)
            }
            try await refreshInstalledApps()
            guard stillActive() else { return }
            await reuploadReferencedAppsLocked()
            guard stillActive() else { return }
            guard await markSessionReady(for: token) else { return }
            let defaults = UserDefaults.standard
            if defaults.data(forKey: WatchScopedKey.buttonSelections.rawValue) != nil {
                try? await setButtons(ButtonStore.selections)
            }
            if await MainActor.run(body: { NotificationIconStore.shared.isEnabled }) {
                try? await setNotificationConfigurations()
            }
            let upperKey = WatchScoped.key(.customWidgetUpper, watchID: token.watchID)
            let lowerKey = WatchScoped.key(.customWidgetLower, watchID: token.watchID)
            if defaults.object(forKey: upperKey) != nil || defaults.object(forKey: lowerKey) != nil {
                try? await setCustomWidgetText(
                    upper: defaults.string(forKey: upperKey) ?? "",
                    lower: defaults.string(forKey: lowerKey) ?? "")
            }
            await WeatherProvider.shared.pushIfEnabled()
            await CalendarSync.shared.syncIfEnabled()
            guard stillActive() else { return }
            // A watch reconnecting mid-window (e.g. at 23:00) goes quiet
            // right away instead of waiting for the next maintenance tick.
            await QuietHoursManager.shared.evaluate()
            await syncActivityIfDue()
            await refreshActiveWatchfaceImage()
        } catch {
            guard stillActive() else { return }
            addLog("Init failed: \(error.localizedDescription)")
            await MainActor.run {
                // Stay usable for debugging even if part of init failed.
                self.connectionState = self.isAuthenticated ? .ready : .failed(error.localizedDescription)
            }
        }
    }

    /// Reads the watch's configuration file (encrypted). This is the only
    /// battery source on the Hybrid HR — it has no standard battery service.
    /// Returns the parsed config so callers (e.g. init) can reuse it instead
    /// of paying for a second encrypted round-trip.
    @discardableResult
    func readConfiguration() async throws -> WatchConfiguration? {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await readConfigurationLocked() }
    }

    @discardableResult
    private func readConfigurationLocked() async throws -> WatchConfiguration? {
        let watchID = WatchSession.connectionToken?.watchID
        guard let config = try await fetchConfiguration() else { return nil }
        addLog("Config: battery=\(config.batteryPercentage.map(String.init) ?? "?")% " +
               "(\(config.batteryVoltageMV.map { "\($0)mV" } ?? "?")), " +
               "steps=\(config.currentStepCount.map(String.init) ?? "?"), " +
               "goal=\(config.dailyStepGoal.map(String.init) ?? "?")")
        await MainActor.run {
            if let level = config.batteryPercentage {
                self.batteryLevel = level
                self.batteryObservationDate = Date()
            }
            if let steps = config.currentStepCount {
                self.watchStepCount = steps
                if let watchID {
                    FitnessStore.shared.recordLiveStepCount(steps, for: watchID)
                }
            }
        }
        if let level = config.batteryPercentage {
            BatteryWatcher.shared.check(level: level)
        }
        // Keep the watch's calorie-model inputs in sync with what the user set
        // in our Body metrics screen, using the profile we just read so no
        // second round-trip is needed.
        try? await reapplyBodyProfileIfNeeded(config)
        return config
    }

    /// Reads and decrypts the configuration file (0x0800), returning the parsed
    /// items. Shared by `readConfiguration` and the body-metrics writer.
    private func fetchConfiguration() async throws -> WatchConfiguration? {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await fetchConfigurationLocked() }
    }

    /// Lookup → handshake → encrypted get. The handshake and the get must not
    /// be split by another operation's handshake, hence the session.
    private func fetchConfigurationLocked() async throws -> WatchConfiguration? {
        let key = try activeWatchKey()
        let lookup = FileLookupRequest(major: FossilFileHandle.configuration.major)
        try await run(lookup)
        guard !lookup.fileEmpty, let handle = lookup.resolvedHandle else { return nil }

        let randoms = try await authenticate()
        let get = FileEncryptedGetRequest(handle: handle, key: key,
                                          phoneRandom: randoms.phone, watchRandom: randoms.watch)
        try await run(get)
        return WatchConfiguration.parse(try get.strippedFileData())
    }

    /// Whole years between a birth date and now (how the watch stores DOB —
    /// body-profile byte 0 is age, not a date).
    static func ageYears(from birth: Date, now: Date = Date()) -> Int {
        max(0, Calendar.current.dateComponents([.year], from: birth, to: now).year ?? 0)
    }

    /// Sets the watch's body profile (config item 0x0001) — age (from DOB),
    /// gender, height and weight — which feed the firmware's own daily-calorie
    /// estimate. Read-modify-write so the unknown byte 6 is preserved.
    func setBodyProfile(gender: ConfigItem.Gender, heightCm: Int, weightKg: Int,
                        birthDate: Date) async throws {
        // Read-modify-write: the read and the write must see the same config.
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await setBodyProfileLocked(gender: gender, heightCm: heightCm,
                                           weightKg: weightKg, birthDate: birthDate)
        }
    }

    private func setBodyProfileLocked(gender: ConfigItem.Gender, heightCm: Int, weightKg: Int,
                                      birthDate: Date) async throws {
        let age = Self.ageYears(from: birthDate)
        let base = try await fetchConfiguration()?.bodyProfileRaw
        try await writeConfig([.bodyProfile(base: base, ageYears: age, gender: gender,
                                            heightCm: heightCm, weightKg: weightKg)])
        let defaults = UserDefaults.standard
        defaults.set(heightCm, forKey: WatchScopedKey.bodyHeightCm.rawValue)
        defaults.set(weightKg, forKey: WatchScopedKey.bodyWeightKg.rawValue)
        defaults.set(gender.rawValue, forKey: WatchScopedKey.bodyGender.rawValue)
        defaults.set(birthDate.timeIntervalSince1970, forKey: WatchScopedKey.bodyBirth.rawValue)
        addLog("Body profile set: age \(age), gender \(gender.rawValue), \(heightCm) cm, \(weightKg) kg")
    }

    /// Re-pushes the stored body profile on init when the watch's copy has
    /// drifted (a factory reset, an official-app sync, or simply a birthday
    /// advancing the age). No-op unless the user has saved a profile in our app.
    private func reapplyBodyProfileIfNeeded(_ config: WatchConfiguration) async throws {
        let defaults = UserDefaults.standard
        guard let height = defaults.object(forKey: WatchScopedKey.bodyHeightCm.rawValue) as? Int,
              let weight = defaults.object(forKey: WatchScopedKey.bodyWeightKg.rawValue) as? Int,
              let genderRaw = defaults.object(forKey: WatchScopedKey.bodyGender.rawValue) as? Int,
              let gender = ConfigItem.Gender(rawValue: genderRaw),
              let birthTS = defaults.object(forKey: WatchScopedKey.bodyBirth.rawValue) as? Double
        else { return }
        let age = Self.ageYears(from: Date(timeIntervalSince1970: birthTS))
        guard config.heightCm != height || config.weightKg != weight
            || config.gender != genderRaw || config.ageYears != age else { return }
        try await writeConfig([.bodyProfile(base: config.bodyProfileRaw, ageYears: age,
                                            gender: gender, heightCm: height, weightKg: weight)])
        addLog("Body profile re-applied: age \(age), gender \(genderRaw), \(height) cm, \(weight) kg")
    }

    /// Re-pushes every global setting supported by Hybrid HR on connect.
    /// This is intentionally unconditional: some items cannot be read back,
    /// and a newly-added or reset watch must still inherit the shared setup.
    private func reapplyDeviceSettingsIfNeeded(_: WatchConfiguration) async throws {
        let defaults = UserDefaults.standard
        let stepGoal = defaults.object(forKey: "stepGoal") as? Int ?? 10000
        let vibration = defaults.object(forKey: WatchScopedKey.vibrationStrength.rawValue) as? Int ?? 100
        let useMetric = defaults.object(forKey: "useMetric") as? Bool ?? true
        let heartRateMode = defaults.object(forKey: "heartRateMode") as? Int ?? -1
        var items: [ConfigItem] = [
            .dailyStepGoal(UInt32(stepGoal)),
            .vibrationStrength(UInt8(vibration)),
            .units(useMetric ? 8 : (8 | 4 | 1)),
            .heartRateMode(Int8(heartRateMode)),
        ]
        if let data = defaults.data(forKey: "workoutDetection"),
           let detection = try? JSONDecoder().decode(WorkoutDetectionSettings.self, from: data) {
            items.append(.fitnessDetection(detection))
        }
        if defaults.object(forKey: "inactivityEnabled") != nil {
            let enabled = defaults.bool(forKey: "inactivityEnabled")
            let minutes = defaults.object(forKey: "inactivityMinutes") as? Int ?? 60
            let start = defaults.object(forKey: "inactivityStart") as? Int ?? 8 * 60
            let end = defaults.object(forKey: "inactivityEnd") as? Int ?? 20 * 60
            items.append(.inactivityWarning(
                from: (UInt8(start / 60), UInt8(start % 60)),
                until: (UInt8(end / 60), UInt8(end % 60)),
                minutes: UInt8(minutes), enabled: enabled))
        }
        try await writeConfig(items)
        addLog("Global settings applied: goal \(stepGoal), vibration \(vibration), metric \(useMetric), heart rate \(heartRateMode)")
    }

    /// Downloads a file by handle for the debug file manager, returning the
    /// full file bytes (12-byte header + trailing CRC included, matching the raw
    /// path). On watches with encryption, the configuration (0x08) and activity
    /// (0x01) files are AES-CTR encrypted at rest — the watch's transport CRC is
    /// over the plaintext, so a raw download of those CRC-mismatches; route them
    /// through the authenticated encrypted get (mirrors readConfiguration) so
    /// the exported .bin is decrypted and diffable.
    func downloadForExport(handle: UInt16) async throws -> Data {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await downloadForExportLocked(handle: handle) }
    }

    private func downloadForExportLocked(handle: UInt16) async throws -> Data {
        let major = UInt8((handle >> 8) & 0xFF)
        let encryptedMajors: Set<UInt8> = [FossilFileHandle.configuration.major,
                                           FossilFileHandle.activity.major]
        // The activity file is not a "cooked" [handle][length@8][payload]
        // [crc32c] container on either family — offset 8 is a Unix timestamp,
        // not a length (see syncActivityLocked) — so it can't go through the
        // generic container validation the other exported handles expect.
        let isActivity = major == FossilFileHandle.activity.major

        let lookup = FileLookupRequest(major: major)
        var target = handle
        if (try? await run(lookup)) != nil, !lookup.fileEmpty,
           let resolved = lookup.resolvedHandle {
            target = resolved
        }

        if WatchSession.connectionToken?.kind.needsAuthKey == true && encryptedMajors.contains(major) {
            let key = try activeWatchKey()
            let randoms = try await authenticate()
            let get = FileEncryptedGetRequest(handle: target, key: key,
                                              phoneRandom: randoms.phone, watchRandom: randoms.watch)
            try await run(get)
            guard let raw = get.fileData else {
                throw FossilError.unexpectedResponse("file download did not complete")
            }
            return isActivity ? raw : try get.validatedFileData()
        }

        let get = FileGetRawRequest(handle: target)
        try await run(get)
        guard let raw = get.fileData else {
            throw FossilError.unexpectedResponse("file download did not complete")
        }
        return isActivity ? raw : try get.validatedFileData()
    }

    /// Vibrates the watch for up to 30 s so it can be found
    /// Returns whether the user
    /// pressed a watch button to acknowledge. Firmware < 2.22 ignores the
    /// command, so refuse early with a clear error.
    @discardableResult
    func findWatch() async throws -> Bool {
        let firmware = await MainActor.run { FirmwareVersion(self.firmwareVersion) }
        guard firmware?.atLeast(2, 22) ?? true else {
            throw FossilError.unexpectedResponse("Find watch needs firmware 2.22 or newer")
        }
        return try await WatchSession.exclusive(for: connectionTokenSync()) {
            let request = ConfirmOnDeviceRequest()
            try await self.run(request)
            self.addLog(request.confirmed ? "Find watch: confirmed on watch" : "Find watch: timed out")
            return request.confirmed
        }
    }

    /// Vibrates a Q hybrid to be found and waits for the middle-button
    /// acknowledgement. Returns whether the user pressed a button; a lapsed
    /// vibration window surfaces as `FossilError.timeout` from `run`, which we
    /// map to "not confirmed" rather than an error. The button press already
    /// stops the vibration watch-side; the stop write covers the timeout path
    /// (and is harmless after a press).
    @discardableResult
    func findQWatch() async throws -> Bool {
        return try await WatchSession.exclusive(for: connectionTokenSync()) {
            let request = QConfirmOnDeviceRequest()
            do {
                try await self.run(request)
            } catch FossilError.timeout {
                // No press within the watch's ~30 s window — leave unconfirmed.
            }
            try? await self.run(QVibrateRequest(start: false))
            self.addLog(request.confirmed ? "Find watch: confirmed on watch" : "Find watch: timed out")
            return request.confirmed
        }
    }

    /// Vibrates the active watch so it can be found, branching per family
    /// shared by the Dashboard Find affordance and My Watches' row action so
    /// the two don't drift. Both families confirm via a button press within
    /// the vibration window (HR: `findWatch`; Q: `findQWatch`).
    func findActiveWatchAndConfirm() async throws -> Bool? {
        let token = connectionTokenSync()
        return try await WatchSession.exclusive(for: token) {
            guard let token = WatchSession.connectionToken else { throw FossilError.staleConnection }
            return token.kind.needsAuthKey ? try await self.findWatch()
                                           : try await self.findQWatch()
        }
    }

    /// Adoption trust gate for an HR watch: buzz it and wait for the user to
    /// press a button, proving the watch in their hand is the one being added
    /// — the same confirmation the official app requires, so a stranger's
    /// nearby watch can't be added by accident. Returns whether adoption may
    /// proceed. Firmware < 2.22 can't vibrate-confirm, so it's admitted (no
    /// gate is available there). Runs with the session already held (called
    /// from init); drives the `awaitingAdoptionConfirm` overlay.
    private func confirmAdoption() async -> Bool {
        let firmware = await MainActor.run { FirmwareVersion(self.firmwareVersion) }
        guard firmware?.atLeast(2, 22) ?? true else {
            addLog("Adoption: firmware < 2.22 — vibrate-confirm unavailable, admitting")
            return true
        }
        await MainActor.run { self.awaitingAdoptionConfirm = true }
        let request = ConfirmOnDeviceRequest()
        var confirmed = false
        do {
            try await run(request)
            confirmed = request.confirmed
        } catch {
            // A timeout, a cancel, or a dropped link all mean "not confirmed".
            addLog("Adoption confirm ended: \(error.localizedDescription)")
        }
        await MainActor.run { self.awaitingAdoptionConfirm = false }
        addLog(confirmed ? "Adoption: confirmed on watch" : "Adoption: not confirmed")
        return confirmed
    }

    /// Wipes the watch back to factory state. The watch reboots and drops the
    /// connection; it will need a full re-setup afterwards.
    func factoryReset() async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await self.run(FactoryResetRequest())
            self.addLog("Factory reset sent — watch is rebooting")
        }
    }

    /// Launches an installed watch app. Only works
    /// while a customWatchFace-based face is active — stock faces are.
    func startAppOnWatch(_ appName: String) async throws {
        try await pushJson(JsonPayloads.startApp(appName))
        addLog("Started \(appName) on watch")
    }

    /// Pushes text into a custom-text widget on the currently active face.
    func setCustomWidgetText(index: Int = 0, upper: String, lower: String) async throws {
        try await pushJson(JsonPayloads.customWidgetText(index: index, upper: upper, lower: lower))
        addLog("Custom widget \(index) text updated")
    }


    // MARK: - Notification icons

    /// Uploads the notification icon assets (0x0701) and the per-app filter
    /// file (0x0C00) so ANCS notifications show the right icon
    /// (GB: setNotificationConfigurations). The watch matches entries by
    /// CRC32 of the ANCS app identifier — the iOS bundle ID.
    func setNotificationConfigurations() async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await setNotificationConfigurationsLocked() }
    }

    private func setNotificationConfigurationsLocked() async throws {
        let icons = await MainActor.run { NotificationIconStore.shared.iconAssets() }
        let filters = await MainActor.run { NotificationIconStore.shared.filters() }

        let iconFile = WatchNotificationIcon.file(icons)
        try await run(FilePutRequest(handle: .assetNotificationImages, file: iconFile,
                                     fileVersion: fileVersions.version(for: .assetNotificationImages)))
        try await run(FilePutRequest(handle: .notificationFilter,
                                     file: NotificationFilterFile.encode(filters),
                                     fileVersion: fileVersions.version(for: .notificationFilter)))
        // The user's day filter is now on the watch — let quiet hours re-push
        // the night variant on the next evaluate() if a window is active.
        QuietHoursManager.shared.noteDayFilterApplied()
        addLog("Notification config: \(icons.count) icons, \(filters.count) filters")
    }

    /// Swaps just the filter file (0x0C00) between the user's day
    /// configuration and quiet hours' block-everything set — the icon assets
    /// (0x0701) never need to change. Used by QuietHoursManager; init/UI keep
    /// using setNotificationConfigurations() to push both files together.
    func setNotificationFilter(night: Bool) async throws {
        let file: Data
        if night {
            file = NotificationFilterFile.nightFilter()
        } else {
            let filters = await MainActor.run { NotificationIconStore.shared.filters() }
            file = NotificationFilterFile.encode(filters)
        }
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await self.run(FilePutRequest(handle: .notificationFilter, file: file,
                                              fileVersion: self.fileVersions.version(for: .notificationFilter)))
        }
        addLog(night ? "Notification filter: night (blocking all)" : "Notification filter: day")
    }

    /// Shows an app-generated notification on the watch, bypassing ANCS
    /// (GB: PlayTextNotificationRequest). Used for the test button.
    func playNotification(sender: String, message: String) async throws {
        let file = NotificationPlayFile.encode(kind: .notification, packageName: "generic",
                                               sender: sender, message: message)
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await self.run(FilePutRequest(handle: .notificationPlay, file: file,
                                              fileVersion: self.fileVersions.version(for: .notificationPlay)))
        }
    }

    func fetchDeviceInfo() async throws {
        let request = FileGetRawRequest(handle: .deviceInfo)
        try await run(request)
        fileVersions = DeviceFileVersions(deviceInfoFile: try request.strippedFileData())
    }

    /// Runs the key handshake. Also called before every encrypted file write —
    /// the firmware wants fresh randoms per encrypted put 
    ///
    /// Returns the session randoms it produced. Encrypted transfers must use
    /// *this* return value rather than reading `phoneRandom`/`watchRandom`
    /// back off the manager: those are shared mutable state, and reading them
    /// later is what let a concurrent handshake substitute its own randoms
    /// under an in-flight transfer. Callers are additionally serialized by
    /// `WatchSession.exclusive`; the return value keeps the invariant local
    /// and checkable rather than depending on that from a distance.
    @discardableResult
    func authenticate() async throws -> (phone: Data, watch: Data) {
        guard let token = WatchSession.connectionToken else {
            throw FossilError.staleConnection
        }
        let key = try activeWatchKey()
        let previousState = await MainActor.run { self.connectionState }
        await MainActor.run {
            if self.connectionState != .ready { self.connectionState = .authenticating }
        }
        do {
            let request = VerifyPrivateKeyRequest(key: key)
            try await run(request)
            guard let randoms = request.resultRandoms else {
                throw FossilError.authenticationFailed("handshake did not produce session randoms")
            }
            guard await markAuthenticated(for: token) else {
                throw FossilError.staleConnection
            }
            return randoms
        } catch {
            await MainActor.run {
                if self.connectionState == .authenticating { self.connectionState = previousState }
            }
            throw error
        }
    }

    /// Asks the watch whether it is BLE-bonded to this phone and publishes
    /// the answer. Cheap plain-text exchange, safe to run on every init.
    @discardableResult
    func checkDevicePairing() async throws -> Bool {
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            let check = CheckDevicePairingRequest()
            try await run(check)
            let paired = check.isPaired
            await MainActor.run { self.isDevicePaired = paired }
            return paired
        }
    }

    /// Makes the watch initiate BLE pairing: iOS shows the system pairing
    /// dialog, then the notifications prompt. Only ever call this from an
    /// explicit user action — the dialog would otherwise pop up on every
    /// background reconnect.
    func performDevicePairing() async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            let perform = PerformDevicePairingRequest()
            try await run(perform)
            let paired = perform.isPaired
            await MainActor.run { self.isDevicePaired = paired }
            addLog(paired ? "iOS pairing successful"
                                    : "iOS pairing failed or was declined")
            if !paired {
                throw FossilError.unexpectedResponse("watch reported pairing failure")
            }
        }
    }

    /// Encrypted configuration write (handle 0x0800), preceded by a fresh
    /// handshake.
    func writeConfig(_ items: [ConfigItem]) async throws {
        // Handshake + encrypted put must not be split by another operation.
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await writeConfigLocked(items) }
    }

    private func writeConfigLocked(_ items: [ConfigItem]) async throws {
        // The non-HR Q hybrids take the same TLV file, just unencrypted —
        // one branch here keeps setTime() and every settings screen working
        // on both families.
        guard WatchSession.connectionToken?.kind.hasEncryptedFiles == true else {
            try await writeConfigPlain(items)
            return
        }
        let key = try activeWatchKey()
        let randoms = try await authenticate()
        let request = FileEncryptedPutRequest(handle: FossilFileHandle.configuration.rawValue,
                                              file: ConfigItem.encodeFile(items),
                                              key: key,
                                              phoneRandom: randoms.phone,
                                              watchRandom: randoms.watch)
        try await run(request)
    }

    func setTime() async throws {
        try await writeConfig([.currentTime()])
        addLog("Time set")
    }

    func setAlarms(_ alarms: [WatchAlarm]) async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            let version = self.fileVersions.version(for: .alarms)
            let file = version == 0x03
                ? WatchAlarm.encodeFile(alarms)
                : WatchAlarm.encodeLegacyFile(alarms)
            let request = FilePutRequest(handle: .alarms, file: file, fileVersion: version)
            try await self.run(request)
            self.addLog("Alarms updated (\(alarms.filter(\.enabled).count) active, format \(version))")
        }
    }

    func refreshInstalledApps() async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await refreshInstalledAppsLocked() }
    }

    private func refreshInstalledAppsLocked() async throws {
        let lookup = FileLookupRequest(major: FossilFileHandle.appCode.major)
        try await run(lookup)
        if lookup.fileEmpty {
            await MainActor.run { self.installedApps = [] }
            return
        }
        guard let handle = lookup.resolvedHandle else { return }
        let get = FileGetRawRequest(handle: handle)
        try await run(get)
        let raw = try get.validatedFileData()
        let apps = InstalledApp.parseList(fromRawFile: raw)
        await MainActor.run { self.installedApps = apps }
        addLog("Installed apps: \(apps.map(\.name).joined(separator: ", "))")
    }

    private func jsonIndexKey(for watchID: UUID) -> String {
        WatchScoped.key(.jsonPushIndex, watchID: watchID)
    }

    /// Raw JSON push to a UI_CONTROL handle (0x05xx, incrementing low byte).
    func pushJson(_ json: Data) async throws {
        // The JSON channel (0x05XX puts consumed by the watchface engine)
        // only exists on the HR. Weather/calendar/music observers can fire
        // while a Q is active — refuse here, the single choke point.
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            guard let token = WatchSession.connectionToken else { throw FossilError.staleConnection }
            guard token.kind.hasJsonPush else {
                throw FossilError.unexpectedResponse("watch has no JSON channel")
            }
            let defaults = UserDefaults.standard
            let key = self.jsonIndexKey(for: token.watchID)
            let index = defaults.integer(forKey: key)
            defaults.set((index + 1) & 0xFF, forKey: key)
            let handle = UInt16(0x0500) | UInt16(index & 0xFF)
            try await self.run(FilePutRawRequest(handle: handle, file: json))
        }
    }

    func activateWatchface(named name: String) async throws {
        // Held across the theme push and the preview read-back so the two
        // stay one atomic sequence (and so refreshActiveWatchfaceImage is
        // always reached with the session held).
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            guard let token = WatchSession.connectionToken else { throw FossilError.staleConnection }
            try await self.pushJson(JsonPayloads.selectTheme(name))
            guard self.validatesConnectionToken(token) else { throw FossilError.staleConnection }
            self.addLog("Activated watchface \(name)")
            UserDefaults.standard.set(
                name, forKey: WatchScoped.key(.activeWatchfaceName, watchID: token.watchID))
            await MainActor.run { self.activeWatchfaceName = name }
            await self.refreshActiveWatchfaceImage()
        }
    }

    /// Downloads the active watchface's .wapp back from the watch and decodes
    /// its background for the dashboard preview (GB: downloadFile +
    /// FossilFileReader). Best-effort: failures just leave the image empty.
    func refreshActiveWatchfaceImage() async {
        guard let token = WatchSession.connectionToken,
              validatesConnectionToken(token) else { return }
        let watchfaces = await MainActor.run { self.installedApps.filter(\.isWatchface) }
        var name = await MainActor.run { self.activeWatchfaceName }
        // If we never activated a face (or it was uninstalled), the only
        // guess the protocol allows is a sole installed watchface.
        if name == nil || !watchfaces.contains(where: { $0.name == name }) {
            name = watchfaces.count == 1 ? watchfaces[0].name : nil
        }
        guard let name, let app = watchfaces.first(where: { $0.name == name }) else {
            await MainActor.run { self.activeWatchfaceImage = nil }
            return
        }
        do {
            let get = FileGetRawRequest(handle: app.fullHandle)
            try await run(get)
            let raw = try get.validatedFileData(expectedHandle: FossilFileHandle.appCode.rawValue)
            let image = WappReader.backgroundImage(fromWapp: raw).map {
                WatchfacePreviewRenderer.render(background: $0,
                                                widgets: WappReader.widgets(fromWapp: raw),
                                                texts: WappReader.textLayers(fromWapp: raw))
            }
            guard validatesConnectionToken(token) else { return }
            UserDefaults.standard.set(
                name, forKey: WatchScoped.key(.activeWatchfaceName, watchID: token.watchID))
            await MainActor.run {
                self.activeWatchfaceName = name
                self.activeWatchfaceImage = image
            }
            addLog("Watchface preview: \(name) (\(raw.count) bytes, image \(image == nil ? "not found" : "decoded"))")
        } catch {
            addLog("Watchface preview failed: \(error.localizedDescription)")
        }
    }

    /// The image to show on the dashboard hero for the active watch: the live
    /// face downloaded from the watch when available, otherwise the bundled
    /// face's local artwork matched by the persisted active-face name (so the
    /// hero previews the chosen face offline / before connecting / after relaunch).
    var activeWatchfacePreviewImage: UIImage? {
        activeWatchfaceImage ?? BundledFaces.matching(name: activeWatchfaceName)?.thumbnail
    }

    func deleteApp(_ app: InstalledApp) async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await deleteAppLocked(app) }
    }

    private func deleteAppLocked(_ app: InstalledApp) async throws {
        try await run(FileDeleteRequest(handle: app.fullHandle))
        try await refreshInstalledApps()
    }

    /// Downloads any installed app/watchface's raw .wapp bytes back from the
    /// watch (GB: downloadFile). Apps aren't encrypted at rest like config/
    /// activity, so this is a plain get against the app's own handle — no
    /// lookup needed, `fullHandle` already came off the app list.
    func downloadApp(_ app: InstalledApp) async throws -> Data {
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            let get = FileGetRawRequest(handle: app.fullHandle)
            try await self.run(get)
            return try get.validatedFileData(expectedHandle: FossilFileHandle.appCode.rawValue)
        }
    }

    /// Uploads a complete .wapp (already contains the 12-byte header + CRC)
    /// and, for watchfaces, activates it. Any installed app/watchface with the
    /// same name is deleted first: re-pushing an unchanged selected_theme is a
    /// no-op on the watch, so a same-name reinstall would keep running the old
    /// code.
    func installWatchface(wapp: Data, name: String) async throws {
        try await putAppFile(wapp, name: name, activateAsWatchface: true)
    }

    /// Installs an arbitrary .wapp (watch app or watchface) via the generic
    /// header-included file upload. Reads the type/name from the file itself
    /// and only theme-activates watchfaces (type 0x01). 
    func installApp(wapp: Data) async throws {
        guard WappReader.isValidContainer(wapp) else {
            throw FossilError.unexpectedResponse("Not a valid .wapp file")
        }
        guard let meta = WappReader.metadata(fromWapp: wapp) else {
            throw FossilError.unexpectedResponse("Could not read the .wapp header")
        }
        try await putAppFile(wapp, name: meta.name, activateAsWatchface: meta.isWatchface)
        addLog("Installed \(meta.isWatchface ? "watchface" : "app") \(meta.name)")
    }

    /// Flashes a DFU firmware image (GB: FirmwareFilePutRequest). The watch
    /// validates the image itself, applies it after the transfer and reboots
    /// — the connection drop right after a clean close is the success path.
    /// Callers must have verified `FirmwareReader.isFirmware` and should keep
    /// the app foregrounded for the whole transfer.
    func installFirmware(_ firmware: Data) async throws {
        // Family guard FIRST: a Hybrid HR DFU image streamed to a hands-only Q
        // watch's OTA handle can brick hardware that is no longer manufactured
        // or serviced. Only the HR takes these images.
        let token = connectionTokenSync()
        guard token?.kind == .hybridHR else {
            throw FossilError.unexpectedResponse("Firmware flashing is only supported on the Hybrid HR")
        }
        guard FirmwareReader.isFirmware(firmware) else {
            throw FossilError.unexpectedResponse("Not a Hybrid HR firmware image")
        }
        let battery = await MainActor.run { self.batteryLevel }
        if let battery, battery < 50 {
            throw FossilError.unexpectedResponse("Watch battery below 50% — charge before flashing")
        }
        let version = FirmwareReader.version(firmware) ?? "?"
        addLog("Flashing firmware \(version) (\(firmware.count) bytes)…")
        try await WatchSession.exclusive(for: token) {
            try await self.run(FirmwareFilePutRequest(firmware: firmware))
        }
        addLog("Firmware transferred — watch is installing and will reboot")
    }

    /// Installs the bundled Home Assistant control app.
    func installHomeAssistantApp() async throws {
        try await installBundledApp(named: "homeAssistantApp")
    }

    /// Installs a `.wapp` shipped in Resources/fossil_hr by identifier.
    private func installBundledApp(named identifier: String) async throws {
        guard let url = Bundle.main.url(forResource: identifier, withExtension: "wapp",
                                        subdirectory: "fossil_hr"),
              let wapp = try? Data(contentsOf: url) else {
            throw FossilError.unexpectedResponse("\(identifier).wapp is not bundled")
        }
        try await installApp(wapp: wapp)
    }

    private func putAppFile(_ wapp: Data, name: String, activateAsWatchface: Bool) async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await putAppFileLocked(wapp, name: name, activateAsWatchface: activateAsWatchface)
        }
    }

    private func putAppFileLocked(_ wapp: Data, name: String, activateAsWatchface: Bool) async throws {
        try await refreshInstalledApps()
        // The watch lists apps by identifier (the code entry's name), which
        // can differ from the display_name `name` was read from — match both,
        // or a reinstall leaves the old copy behind and can run the watch out
        // of memory for the new one.
        let staleNames = Set([name, WappReader.identifier(fromWapp: wapp)].compactMap { $0 })
        let stale = await MainActor.run {
            self.installedApps.filter { staleNames.contains($0.name) }
        }
        for app in stale {
            addLog("Deleting old \(app.name) before reinstall")
            try await run(FileDeleteRequest(handle: app.fullHandle))
        }
        let handle = wapp.u16LE(at: 0)
        try await run(FilePutRawRequest(handle: handle, file: wapp))
        try await refreshInstalledApps()
        if activateAsWatchface {
            try await activateWatchface(named: name)
            // The listing right after the put can still show an app the watch
            // hasn't finished evicting internally (seen as a stale extra face
            // until the user taps Refresh); the activation round-trip gives it
            // time to settle, so re-list once more here as a courtesy — best
            // effort, since the install itself already succeeded.
            try? await refreshInstalledApps()
        } else {
            // Keep the bytes so a later switch to a watch that doesn't have
            // this app can re-upload it from the cache instead of needing the
            // (by then disconnected) source watch. Watchfaces aren't cached —
            // only apps are referenced by the global button/menu config.
            UploadedAppStore.shared.remember(name: name, wapp: wapp)
        }
        if let watchID = WatchSession.connectionToken?.watchID {
            CalendarSync.invalidateDelivery(for: watchID)
        }
        if staleNames.contains("ringPhoneApp") {
            _ = await PhoneFinder.shared.prepareNotificationFallback()
        }
    }

    /// Re-uploads any app referenced by the global button config that
    /// isn't installed on the active watch yet, using bytes cached from a
    /// previous upload to another watch. The config itself is shared across
    /// every compatible watch, but app bytes live only on whichever watch
    /// they were imported to — without this, switching to a second watch
    /// leaves the mapping filtered out by `setButtonsLocked`'s installed-apps
    /// check. HR-only: Q hybrids have no app concept.
    private func reuploadReferencedAppsLocked() async {
        guard let token = WatchSession.connectionToken,
              token.kind == .hybridHR else { return }
        func stillActive() -> Bool { validatesConnectionToken(token) }
        let referenced = ButtonConfig.referencedAppNames(
            buttonSelections: ButtonStore.selections)
        let installed = await MainActor.run { Set(self.installedApps.map(\.name)) }
        for name in referenced where !installed.contains(name) {
            guard stillActive() else { return }
            guard let data = UploadedAppStore.shared.data(forName: name) else { continue }
            addLog("Re-uploading \(name) cached from another watch")
            try? await putAppFileLocked(data, name: name, activateAsWatchface: false)
        }
    }

    // MARK: - Buttons

    /// Pushes the physical-button → app mapping (`master._.config.buttons`).
    /// Persists the selection, filters it against installed apps (workoutApp
    /// is firmware-built-in and always allowed), and resolves firmware-specific
    /// event strings.
    func setButtons(_ selections: [ButtonSelection]) async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await setButtonsLocked(selections) }
    }

    private func setButtonsLocked(_ selections: [ButtonSelection]) async throws {
        ButtonStore.selections = selections
        let installed = await MainActor.run { Set(self.installedApps.map(\.name)) }
        let firmware = await MainActor.run { FirmwareVersion(self.firmwareVersion) }
        let assignments = ButtonConfig.assignments(userSelections: selections,
                                                   installed: installed, firmware: firmware)
        try await pushJson(JsonPayloads.buttonConfig(assignments))
        addLog("Buttons updated: " +
               assignments.map { "\($0.event)=\($0.appName)" }.joined(separator: ", "))
    }

    /// Battery lives in the encrypted config file (no 0x180F service on the
    /// Hybrid HR).
    func refreshBattery() async throws {
        guard WatchSession.connectionToken?.kind.hasEncryptedFiles == true else {
            try await readConfigurationQ()
            return
        }
        try await readConfiguration()
    }

    // MARK: - Hand calibration

    /// Takes physical control of the hands and moves them to 12:00 so the
    /// user can judge the offset (GB: QHYBRID_COMMAND_CONTROL — GB zeroes
    /// all three hands; the sub-eye only physically exists on the Q).
    func startHandCalibration() async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await startHandCalibrationLocked() }
    }

    private func startHandCalibrationLocked() async throws {
        try await run(RequestHandsControlRequest())
        let sub = WatchSession.connectionToken?.kind.hasSubEye == true ? 0 : nil
        try await run(MoveHandsRequest(relative: false, hour: 0, minute: 0, sub: sub))
        addLog("Hand calibration started")
    }

    /// Nudges hands by signed degrees (positive = clockwise) while
    /// calibration is active.
    func moveHands(hour: Int? = nil, minute: Int? = nil, sub: Int? = nil) async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await self.run(MoveHandsRequest(relative: true, hour: hour, minute: minute, sub: sub,
                                                bumpSingleDegree: WatchSession.connectionToken?.kind.movesHandsMinTwoDegrees == true))
        }
    }

    /// Optionally persists the current positions as the new zero, then
    /// returns hand control to the watch (which re-syncs them to the time).
    func endHandCalibration(save: Bool) async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await endHandCalibrationLocked(save: save) }
    }

    private func endHandCalibrationLocked(save: Bool) async throws {
        if save { try await run(SaveCalibrationRequest()) }
        try await run(ReleaseHandsControlRequest())
        addLog(save ? "Hand calibration saved" : "Hand calibration discarded")
    }

    // MARK: - Fitness

    /// Downloads the activity file, parses it, stores the samples locally and
    /// deletes the file from the watch. Returns the number of new minute
    /// samples.
    @discardableResult
    func syncActivity(retryQuarantined: Bool = true) async throws -> Int {
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await syncActivityLocked(retryQuarantined: retryQuarantined)
        }
    }

    private func syncActivityLocked(retryQuarantined: Bool) async throws -> Int {
        guard let token = WatchSession.connectionToken,
              validatesConnectionToken(token) else { throw FossilError.staleConnection }
        let watchID = token.watchID
        let encrypted = token.kind.hasEncryptedFiles

        let lookup = FileLookupRequest(major: FossilFileHandle.activity.major)
        try await run(lookup)
        if lookup.fileEmpty {
            addLog("Activity file empty — nothing to sync")
            await FitnessStore.shared.setLastSync(Date(), for: watchID)
            return 0
        }
        guard let handle = lookup.resolvedHandle else {
            throw FossilError.unexpectedResponse("activity lookup returned no handle")
        }
        if !retryQuarantined,
           await ActivityQuarantineStore.shared.shouldSkipAutomaticDownload(
                watchID: watchID, handle: handle) {
            addLog("Activity file \(String(handle, radix: 16)) remains quarantined — skipping unchanged automatic download")
            return 0
        }
        if retryQuarantined {
            await ActivityQuarantineStore.shared.noteExplicitRetry(watchID: watchID, handle: handle)
        }

        // Neither variant of the activity file is a "cooked" [handle][length@8]
        // [payload][crc32c] container: offset 8 is a Unix timestamp (byte-
        // identical to the 0xE2 0x04 block at offset 34 in the no-HR file;
        // confirmed by a real Q Grant dump, and matching Gadgetbridge's
        // ActivityFileParser which reads it as a timestamp on both the HR and
        // no-HR branches). Running the generic container's length/CRC32C
        // check against it — as a prior broad audit pass wired in for every
        // FileGetRawRequest/FileEncryptedGetRequest — rejects a valid file.
        // Integrity is already guaranteed by the whole-file transport CRC32
        // verified during download, and structure by the parser's bounds/
        // termination checks (it excludes the trailing 4-byte CRC via
        // file.count - 4). Hand it the raw file, as Gadgetbridge does.
        let fileData: Data
        if encrypted {
            let key = try activeWatchKey()
            // Encrypted download wants fresh session randoms.
            let randoms = try await authenticate()
            let get = FileEncryptedGetRequest(handle: handle, key: key,
                                              phoneRandom: randoms.phone, watchRandom: randoms.watch)
            try await run(get)
            guard let raw = get.fileData else {
                throw FossilError.unexpectedResponse("activity download did not complete")
            }
            fileData = raw
        } else {
            let get = FileGetRawRequest(handle: handle)
            try await run(get)
            guard let raw = get.fileData else {
                throw FossilError.unexpectedResponse("activity download did not complete")
            }
            fileData = raw
        }
        addLog("Activity file: \(fileData.count) bytes")

        let parser: ActivityParser
        do {
            parser = try ActivityParser.parse(fileData)
        } catch let error as ActivityParser.ParseError {
            // Any structural failure — an unsupported version after a firmware
            // update, OR a truncated/corrupt file — would otherwise wedge sync
            // forever: the file is never deleted, so every sync re-downloads it
            // and re-fails, silently (syncActivityIfDue swallows throws). And a
            // corrupt file that reached a raw read would crash the app on every
            // connect (the parser is fully bounds-checked so it can't, but the
            // error path must still not loop). Surface it, leave the file on the
            // watch for export, and pause auto-sync rather than retry tightly.
            let detail: String
            switch error {
            case .unsupportedVersion(let version): detail = "version \(version) is not supported"
            case .tooShort: detail = "the file is truncated or corrupt"
            case .truncated(let offset, let context):
                detail = "the file is truncated at byte \(offset) (\(context))"
            case .invalidRecord(let offset, _):
                detail = "the file contains an invalid record at byte \(offset)"
            case .invalidWorkout(let offset, let context):
                detail = "the workout at byte \(offset) is invalid (\(context))"
            case .invalidTermination(let offset):
                detail = "the activity stream ends incorrectly at byte \(offset)"
            }
            do {
                try await ActivityQuarantineStore.shared.quarantine(
                    fileData, watchID: watchID, handle: handle,
                    failureCategory: String(describing: error))
                addLog("⚠️ Activity file: \(detail) — quarantined. The file remains on the watch and can be exported from Fitness.")
            } catch {
                addLog("⚠️ Activity file: \(detail). Raw quarantine save failed: \(error.localizedDescription); the watch copy is retained.")
            }
            await MainActor.run {
                ToastCenter.shared.error(String(localized: "Unreadable activity file — retained for retry or export"))
            }
            return 0
        }
        guard parser.isComplete else {
            throw FossilError.unexpectedResponse("activity parser did not reach a complete state")
        }
        addLog("Parsed \(parser.samples.count) samples, \(parser.spo2Samples.count) SpO2, \(parser.workouts.count) workouts")

        try Task.checkCancellation()
        guard validatesConnectionToken(token) else { throw FossilError.staleConnection }
        let (newCount, persisted) = await FitnessStore.shared.merge(
            samples: parser.samples,
            spo2: parser.spo2Samples,
            workouts: parser.workouts,
            from: watchID)

        // Clear the file on the watch so it doesn't grow / get re-synced —
        // but only once the merge is actually on disk. The watch's copy is
        // the sole backup: deleting it after a failed save (a locked device
        // during a background sync, a full disk) would lose the window for
        // good. Leaving it means the next sync re-downloads and re-merges,
        // which dedups.
        guard persisted else {
            addLog("Activity merged but not persisted — keeping the file on the watch to retry")
            return newCount
        }
        try Task.checkCancellation()
        guard validatesConnectionToken(token) else { throw FossilError.staleConnection }
        try await run(FileDeleteRequest(handle: handle))
        await ActivityQuarantineStore.shared.clear(watchID: watchID)
        addLog("Activity file deleted on watch (\(newCount) new samples)")

        // Refresh the watch's authoritative daily step counter so the Fitness
        // "Today" total (which prefers it over the approximate minute-sample
        // sum) is current right after a sync.
        try? await refreshBattery()
        return newCount
    }

    /// Minimum spacing between automatic activity syncs. Manual syncs (the
    /// Fitness screen button) are never throttled.
    static let autoSyncInterval: TimeInterval =  5 * 60

    /// How often the foreground timer runs `periodicMaintenance`.
    static let maintenanceInterval: TimeInterval = 60
    /// Minimum spacing between maintenance runs, so the foreground trigger
    /// doesn't re-hit the watch on every app switch.
    static let maintenanceMinInterval: TimeInterval = 5 * 60

    /// Keeps a connected watch fresh while the app is open: clock, battery +
    /// step counter, and a due activity sync. The on-connect init already does
    /// all of this, so it only matters for long-lived connections. Runs from
    /// the periodic timer and the will-enter-foreground notification.
    func periodicMaintenance() async {
        try? await WatchSession.exclusive(for: connectionTokenSync()) { await periodicMaintenanceLocked() }
    }

    private func periodicMaintenanceLocked() async {
        let due = await MainActor.run {
            guard self.connectionState == .ready,
                  Date().timeIntervalSince(self.lastMaintenanceDate) >= Self.maintenanceMinInterval
            else { return false }
            self.lastMaintenanceDate = Date()
            return true
        }
        guard due, !Self.initInProgress else { return }
        try? await setTime()
        try? await refreshBattery()
        await QuietHoursManager.shared.evaluate()
        await syncActivityIfDue()
    }

    /// Runs `syncActivity()` only if we're connected/authenticated and the
    /// last sync (manual or automatic) is older than `autoSyncInterval`.
    /// Used by the on-connect init sequence and the periodic timer, so a
    /// reconnect right after a manual sync doesn't re-hit the watch.
    func syncActivityIfDue(minInterval: TimeInterval = autoSyncInterval) async {
        try? await WatchSession.exclusive(for: connectionTokenSync()) { await syncActivityIfDueLocked(minInterval: minInterval) }
    }

    private func syncActivityIfDueLocked(minInterval: TimeInterval) async {
        // Connected is enough on the unencrypted Q; the HR also needs the
        // key handshake to have happened.
        let needsAuth = WatchSession.connectionToken?.kind.hasEncryptedFiles == true
        let canSync = await MainActor.run {
            (!needsAuth && self.connectionState == .ready) || self.isAuthenticated
        }
        guard canSync else { return }
        let watchID = WatchSession.connectionToken?.watchID
        let last = await MainActor.run { FitnessStore.shared.lastSync(for: watchID) }
        if let last, Date().timeIntervalSince(last) < minInterval { return }
        do {
            let count = try await syncActivity(retryQuarantined: false)
            if count > 0 { addLog("Auto-sync: \(count) new minute samples") }
        } catch {
            addLog("Auto-sync failed: \(error.localizedDescription)")
        }
    }

    func setWorkoutDetection(_ settings: WorkoutDetectionSettings) async throws {
        try await writeConfig([.fitnessDetection(settings)])
    }

    func setInactivityWarning(enabled: Bool, minutes: Int,
                              from: (Int, Int), until: (Int, Int)) async throws {
        try await writeConfig([.inactivityWarning(from: (UInt8(from.0), UInt8(from.1)),
                                                  until: (UInt8(until.0), UInt8(until.1)),
                                                  minutes: UInt8(minutes),
                                                  enabled: enabled)])
    }

    /// Push a JSON response, waiting briefly if another request is running
    /// (used for replies to watch-initiated events).
    @discardableResult
    func pushJsonWhenIdle(_ json: Data, attempts: Int = 10) async -> Bool {
        guard let token = connectionTokenSync() else { return false }
        return await pushJsonWhenIdle(json, expectedToken: token, attempts: attempts)
    }

    @discardableResult
    func pushJsonWhenIdle(_ json: Data, expectedToken: WatchConnectionToken,
                          attempts: Int = 10) async -> Bool {
#if DEBUG
        let isHomeAssistantResponse = String(data: json, encoding: .utf8)?
            .contains("homeAssistantApp._.config.response") == true
#endif
        for attempt in 0..<attempts {
            do {
                try Task.checkCancellation()
                guard validatesConnectionToken(expectedToken) else {
                    throw FossilError.staleConnection
                }
                try await pushJson(json)
#if DEBUG
                if isHomeAssistantResponse {
                    HomeAssistantLog.print(
                        "BLE response file push acknowledged on attempt \(attempt + 1)/\(attempts)")
                }
#endif
                return true
            } catch {
#if DEBUG
                if isHomeAssistantResponse {
                    HomeAssistantLog.print(
                        "BLE response send attempt \(attempt + 1)/\(attempts) failed: " +
                        error.localizedDescription)
                }
#endif
                if attempt == attempts - 1 {
                    addLog("Failed to answer watch request: \(error.localizedDescription)")
                } else {
                    do { try await Task.sleep(nanoseconds: 500_000_000) }
                    catch { return false }
                }
            }
        }
        return false
    }

    /// Runs a freshly-built request, retrying briefly if another request is
    /// already in flight (used for pushes triggered by watch/OS events that
    /// can race the request queue, e.g. now-playing changes).
    func runWhenIdle(attempts: Int = 10, _ makeRequest: () -> FossilRequest) async {
        for attempt in 0..<attempts {
            do {
                try await WatchSession.exclusive(for: connectionTokenSync()) { try await run(makeRequest()) }
                return
            } catch {
                if attempt == attempts - 1 {
                    addLog("Failed after \(attempts) attempts: \(error.localizedDescription)")
                } else {
                    do { try await Task.sleep(nanoseconds: 500_000_000) }
                    catch { return }
                }
            }
        }
    }

    /// Handles JSON requests the watch pushes on 3dda0006 (workoutApp etc.).
    func handleWatchJsonRequest(_ jsonData: Data) {
        let limiter = WatchRequestLimiter.shared
        guard jsonData.count <= WatchRequestLimiter.maximumJSONBytes,
              limiter.acquire(.frame, limit: 20, per: 1),
              let eventToken = connectionTokenSync() else {
            addLog("Dropped oversized or rate-limited watch JSON request")
            return
        }
#if DEBUG
        let rawJSON = String(data: jsonData, encoding: .utf8) ?? "<non-UTF8>"
        let isHomeAssistant = rawJSON.localizedCaseInsensitiveContains("homeassistant")
        if isHomeAssistant {
            HomeAssistantLog.print("BLE watch JSON received: bytes=\(jsonData.count), json=\(rawJSON)")
        }
#endif
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let request = root["req"] as? [String: Any] else {
#if DEBUG
            if isHomeAssistant {
                HomeAssistantLog.print("BLE watch JSON rejected: expected {\"req\":{...}}")
            }
#endif
            return
        }
        // Some requests carry no id; GB's optInt defaults to 0.
        let requestId = request["id"] as? Int ?? 0

        var responseSet: [String: Any]?

        if let workout = request["workoutApp"] as? [String: Any] {
            let state = workout["state"] as? String ?? ""
            let type = workout["type"] as? String ?? ""
            addLog("workoutApp request: state=\(state) type=\(type)")
            let tracker = WorkoutLocationTracker.shared
            switch (state, type) {
            case ("started", _):
                if (workout["gps"] as? String) == "on" { tracker.start(for: eventToken) }
                responseSet = ["workoutApp._.config.response": ["message": "", "type": "success"]]
            case ("paused", _):
                tracker.pause(for: eventToken)
                responseSet = ["workoutApp._.config.response": ["message": "", "type": "success"]]
            case ("resumed", _):
                tracker.resume(for: eventToken)
                responseSet = ["workoutApp._.config.response": ["message": "", "type": "success"]]
            case ("end", _):
                tracker.stop(for: eventToken)
                responseSet = ["workoutApp._.config.response": ["message": "", "type": "success"]]
            case (_, "req_distance") where tracker.isTracking(for: eventToken):
                // The watch accumulates these deltas itself (GB semantics).
                if let change = tracker.pollChange(for: eventToken) {
                    responseSet = ["workoutApp._.config.gps": ["distance": change.distanceCm,
                                                               "duration": change.durationSecs]]
                }
            case (_, "req_distance"), (_, "req_route"):
                // No GPS running / no route images: the watch falls back to
                // its own sensors (GB replies error here too).
                responseSet = ["workoutApp._.config.response": ["message": "", "type": "error"]]
            default:
                break
            }
        } else if let ring = request["ringMyPhone"] as? [String: Any] {
            let action = ring["action"] as? String ?? ""
            addLog("ringMyPhone request (\(action))")
            DispatchQueue.main.async {
                guard self.validatesConnectionToken(eventToken) else { return }
                action == "on" ? PhoneFinder.shared.start() : PhoneFinder.shared.stop()
            }
            responseSet = ["ringMyPhone": ["result": action]]
        } else if let homeAssistant = request["homeAssistant"] as? [String: Any] {
            let action = homeAssistant["action"] as? String ?? ""
#if DEBUG
            addLog("Home Assistant request (\(action))")
#endif
            guard limiter.acquire(.homeAssistant, limit: 6, per: 10,
                                  maximumConcurrent: 1) else {
                HomeAssistantLog.print("BLE watch Home Assistant request rate-limited")
                return
            }
            HomeAssistantLog.print("BLE watch request dispatched: transportID=\(requestId), action=\(action)")
            Task {
                defer { limiter.release(.homeAssistant) }
                await HomeAssistantBridge.handle(homeAssistant, requestID: requestId,
                                                 connection: eventToken)
            }
        } else if request["weatherInfo"] != nil || request["weatherApp._.config.locations"] != nil {
            addLog("weather request (full)")
            guard limiter.acquire(.weather, limit: 6, per: 60,
                                  maximumConcurrent: 1) else { return }
            Task {
                defer { limiter.release(.weather) }
                await WeatherProvider.shared.respondFullWeather(
                    requestId: requestId, token: eventToken)
            }
        } else if request["widgetChanceOfRain._.config.info"] != nil {
            addLog("weather request (rain widget)")
            guard limiter.acquire(.weather, limit: 6, per: 60,
                                  maximumConcurrent: 1) else { return }
            Task {
                defer { limiter.release(.weather) }
                await WeatherProvider.shared.respondRainWidget(token: eventToken)
            }
        } else if request["widgetUV._.config.info"] != nil {
            addLog("weather request (UV widget)")
            guard limiter.acquire(.weather, limit: 6, per: 60,
                                  maximumConcurrent: 1) else { return }
            Task {
                defer { limiter.release(.weather) }
                await WeatherProvider.shared.respondUVWidget(token: eventToken)
            }
        } else if request["master._.config.app_status"] != nil {
            // The watch reports an app open/close (e.g. weatherApp) and expects
            // an ack (GB: ConfirmAppStatusRequest). Without it the watch retries
            // forever with an ever-incrementing id — a BLE + main-thread log
            // storm that starves the UI (delayed keyboard, input hitches).
            responseSet = ["master._.config.app_status": ["message": "", "type": "success"]]
        } else {
            addLog("Unhandled watch request: \(String(data: jsonData, encoding: .utf8) ?? "?")")
        }

        if let responseSet {
            let response: [String: Any] = ["res": ["id": requestId, "set": responseSet]]
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                Task { await self.pushJsonWhenIdle(data) }
            }
        }
    }
}
