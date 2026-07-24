import Foundation

/// High-level operations for the older, non-HR Q hybrids speaking the
/// unencrypted fossil file protocol. Kept separate
/// from WatchActions.swift, which stays Hybrid-HR-only; shared operations
/// (setTime, setAlarms, writeConfig, hand calibration…) live there and
/// branch on the active watch's kind internally.
extension WatchConnection {

    /// App-level init for a fossil-file-era Q watch.
    /// No authentication anywhere — the protocol is
    /// plaintext.
    func initializeQWatch() async {
        // Same serialization as initializeWatch — see the note there.
        try? await WatchSession.exclusive(for: connectionTokenSync()) {
            self.isInitializing = true
            defer { self.isInitializing = false }
            await initializeQWatchLocked()
        }
    }

    /// The Q init sequence proper. Runs with the session held.
    private func initializeQWatchLocked() async {
        guard let token = WatchSession.connectionToken else { return }
        func stillActive() -> Bool { validatesConnectionToken(token) }
        do {
            let (firmware, model) = await MainActor.run { (self.firmwareVersion, self.modelNumber) }
            addLog("Q init — firmware \(firmware ?? "?"), model \(model ?? "? (2A24 pending)")")
            if autoPairOnNextInit {
                // Freshly added watch: sweep the hands as a visible hello
                try? await run(PairingAnimationRequest())
            }
            try await fetchDeviceInfo()
            guard stillActive() else { return }
            addLog("Q file versions: \(fileVersions.summary)")
            if adoptingNewWatch {
                // Trust gate: the Q protocol has no auth key, so this
                // buzz-and-press is the only proof the watch in the user's
                // hand is the one being added (official-app add flow). Not
                // confirmed → undo the add entirely.
                guard await confirmQAdoption() else {
                    adoptingNewWatch = false
                    autoPairOnNextInit = false
                    await abandonAdoption(token.watchID)
                    return
                }
                adoptingNewWatch = false
                guard stillActive() else { return }
            }
            // Same plain control exchange as the HR path (0x01/0x02 0x16 on
            // 3dda0002 are family-agnostic) — without this, isDevicePaired
            // stays nil for the whole session and the dashboard reads a Q
            // watch as "Unpaired" even when it's actually bonded.
            if let paired = try? await checkDevicePairing(),
               !paired, autoPairOnNextInit {
                try? await performDevicePairing()
            }
            autoPairOnNextInit = false
            try? await syncQSettings()
            try? await setTime()
            try? await readConfigurationQ()
            // Re-push a filter the user has configured. A saved empty list
            // deliberately uses the valid block-everything stub rather than
            // an invalid zero-entry file.
            if QNotificationStore.hasStoredAlerts {
                try? await setQNotificationFilter()
            }
            // Same rule for buttons: only re-push a config the user made.
            if QButtonStore.functions != nil {
                try? await setQButtons()
            }
            guard stillActive() else { return }
            guard await markSessionReady(for: token) else { return }
            // A watch reconnecting mid-window (e.g. at 23:00) goes quiet
            // right away instead of waiting for the next maintenance tick.
            await QuietHoursManager.shared.evaluate()
            await syncActivityIfDue()
            await pushDailyStepBaseline()
        } catch {
            guard stillActive() else { return }
            addLog("Q init failed: \(error.localizedDescription)")
            await MainActor.run { self.connectionState = .failed(error.localizedDescription) }
        }
    }

    /// Adoption trust gate for a Q watch: buzz it and wait for the middle-
    /// button press, the Q counterpart of `confirmAdoption`. The `run`
    /// idle-timeout (surfaced as `FossilError.timeout`) is the no-press case —
    /// nothing is sent when the watch's vibration window lapses. The press
    /// already stops the vibration watch-side; the explicit stop covers the
    /// timeout/cancel paths. Runs with the session already held.
    private func confirmQAdoption() async -> Bool {
        await MainActor.run { self.awaitingAdoptionConfirm = true }
        let request = QConfirmOnDeviceRequest()
        var confirmed = false
        do {
            try await run(request)
            confirmed = request.confirmed
        } catch {
            // Timeout, cancel, or dropped link all mean "not confirmed".
            addLog("Q adoption confirm ended: \(error.localizedDescription)")
        }
        try? await run(QVibrateRequest(start: false))
        await MainActor.run { self.awaitingAdoptionConfirm = false }
        addLog(confirmed ? "Q adoption: confirmed on watch" : "Q adoption: not confirmed")
        return confirmed
    }

    /// Uploads config items as a plaintext put to 0x0800 — the same TLV file
    /// the HR takes encrypted. Reached through writeConfig()'s kind branch.
    func writeConfigPlain(_ items: [ConfigItem]) async throws {
        try await run(FilePutRequest(handle: .configuration,
                                     file: ConfigItem.encodeFile(items),
                                     fileVersion: fileVersions.version(for: .configuration)))
    }

    /// Global settings supported by the hands-only Q family.
    func syncQSettings() async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await syncQSettingsLocked() }
    }

    private func syncQSettingsLocked() async throws {
        let goal = UserDefaults.standard.object(forKey: "stepGoal") as? Int ?? 10000
        let vibration = UserDefaults.standard
            .object(forKey: WatchScopedKey.vibrationStrength.rawValue) as? Int ?? 100
        let useMetric = UserDefaults.standard.object(forKey: "useMetric") as? Bool ?? true
        try await writeConfigPlain([
            .dailyStepGoal(UInt32(goal)),
            .vibrationStrength(UInt8(vibration)),
            .units(useMetric ? 8 : (8 | 4 | 1)),
        ])
        addLog("Q settings synced (goal \(goal), vibration \(vibration), metric \(useMetric))")
    }

    /// Reads the configuration file — plaintext lookup + get, otherwise the
    /// same battery/steps publication as the HR's readConfiguration().
    /// (2A19 also works on the Q watches, but the config file carries the
    /// richer battery data and the step count.)
    func readConfigurationQ() async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) { try await readConfigurationQLocked() }
    }

    private func readConfigurationQLocked() async throws {
        let watchID = WatchSession.connectionToken?.watchID
        let lookup = FileLookupRequest(major: FossilFileHandle.configuration.major)
        try await run(lookup)
        guard !lookup.fileEmpty, let handle = lookup.resolvedHandle else { return }

        let get = FileGetRawRequest(handle: handle)
        try await run(get)
        let content = try get.strippedFileData()

        let config = WatchConfiguration.parse(content)
        addLog("Q config: battery=\(config.batteryPercentage.map(String.init) ?? "?")% " +
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
            }
        }
        if let steps = config.currentStepCount, let watchID {
            await FitnessStore.shared.recordLiveStepCount(steps, for: watchID)
        }
        if let level = config.batteryPercentage {
            BatteryWatcher.shared.check(level: level)
        }
    }

    /// Starts/stops the watch vibration. The start
    /// vibration runs until stopped.
    func vibrateWatch(_ on: Bool) async throws {
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await self.run(QVibrateRequest(start: on))
            self.addLog(on ? "Q vibration started" : "Q vibration stopped")
        }
    }

    // MARK: - Notifications

    /// Uploads the per-app/per-contact hand-position filter (0x0C00) from
    /// the store, in the official iOS app's entry layout.
    func setQNotificationFilter() async throws {
        let alerts = QNotificationStore.alerts
        let file = alerts.isEmpty ? QNotificationFilterFile.nightFilter()
                                  : QNotificationFilterFile.encode(alerts)
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await self.run(FilePutRequest(handle: .notificationFilter,
                                              file: file,
                                              fileVersion: self.fileVersions.version(for: .notificationFilter)))
        }
        // The user's day filter is now on the watch — let quiet hours re-push
        // the night variant on the next evaluate() if a window is active.
        QuietHoursManager.shared.noteDayFilterApplied()
        addLog("Q notification filter uploaded (\(alerts.count) alerts)")
    }

    /// Swaps the filter file between the user's day alerts and quiet hours'
    /// block-everything stub. Used by QuietHoursManager; init/UI keep using
    /// the no-argument setQNotificationFilter() for the user's own config.
    func setQNotificationFilter(night: Bool) async throws {
        let alerts = QNotificationStore.alerts
        let file = night || alerts.isEmpty ? QNotificationFilterFile.nightFilter()
                                           : QNotificationFilterFile.encode(alerts)
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await self.run(FilePutRequest(handle: .notificationFilter, file: file,
                                              fileVersion: self.fileVersions.version(for: .notificationFilter)))
        }
        addLog(night ? "Q notification filter: night (blocking all)" : "Q notification filter: day")
    }

    /// Uploads the top/middle/bottom button functions (0x0600) from the
    /// store.
    func setQButtons() async throws {
        guard let functions = QButtonStore.functions else { return }
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await self.run(FilePutRequest(handle: .settingsButtons,
                                              file: QButtonConfigFile.build(functions),
                                              fileVersion: self.fileVersions.version(for: .settingsButtons)))
        }
        addLog("Q buttons uploaded: \(functions.map(\.rawValue).joined(separator: ", "))")
        if functions.contains(.ringPhone) {
            _ = await PhoneFinder.shared.prepareNotificationFallback()
        }
    }

    /// Plays a test notification that matches `alert`'s filter entry, so the
    /// hands actually move to its position (0x0900 play file; the watch
    /// byte-compares the play file's CRC against the filter entries).
    func playQTestNotification(for alert: QNotificationAlert) async throws {
        let bundleId = alert.kind == .app ? alert.identifier
                                          : QNotificationFilterFile.smsBundleId
        let crc = AppNotificationFilter.ancsCrc(bundleId).u32LE(at: 0)
        let file = NotificationPlayFile.encode(
            kind: alert.kind == .app ? .notification : .text,
            flags: 0x02, packageCrc: crc,
            title: alert.displayName,
            sender: alert.kind == .contact ? alert.identifier : alert.displayName,
            message: "Test from Hybridge",
            messageId: UInt32(Date().timeIntervalSince1970))
        try await WatchSession.exclusive(for: connectionTokenSync()) {
            try await self.run(FilePutRequest(handle: .notificationPlay, file: file,
                                              fileVersion: self.fileVersions.version(for: .notificationPlay)))
        }
    }
}
