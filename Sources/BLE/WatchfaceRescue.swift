import Foundation

/// Emergency recovery from a watchface that puts the watch in a reboot loop.
///
/// A bad `.wapp` crashes the Hybrid HR's watchface engine on every boot: the
/// watch buzzes, reboots, and is only reachable for the seconds in between —
/// far too little for the normal init (device info → authenticate → time →
/// config → app list → …). So while this is armed, a connecting HR skips init
/// entirely and spends its window on one recovery step, re-running on every
/// reconnect until a listing proves it worked.
///
/// **What a crash-looping watch will and will not do** — all established on
/// real hardware, firmware DN1.0.3.0r.v13, and the reason the modes below look
/// the way they do:
///
/// - `lookup`, `get` and `close` (0x09) answer normally. Reads need no
///   authentication — only *contents* of config/activity files are encrypted.
/// - `delete` (0x0B) is answered with **complete silence**, every time, on
///   every handle, even straight after a successful close. The bytes match
///   Gadgetbridge exactly; the firmware simply drops the command while its
///   engine is crashing. So deleting the bad face cannot be the plan.
/// - A file put's *open* is acked and the data streams, but the commit never
///   comes for a handle whose consumer is the crashed engine (the JSON channel
///   `selected_theme` rides on hangs the full window, so switching theme is
///   just as impossible).
/// - A put straight to an app's own slot is refused with "not supported":
///   installs only go to the APP_CODE handle, and the watch picks the slot
///   itself, keyed by the identifier inside the file.
/// - Authenticated commands (factory reset) come back with an ATT error from
///   the watch when the session isn't authenticated.
///
/// What that leaves — and what actually recovered a wedged watch — is
/// `overwriteFace`: see its doc comment.
enum WatchfaceRescueMode: String {
    /// Install a healthy face under the broken face's identifier. The one that
    /// works; see `overwriteFaceRescue`.
    case overwriteFace
    /// Close any stuck file session, then delete every face but one. Kept for
    /// a watch that is *not* crash-looping (where deletes are answered
    /// normally) — a wedged one ignores every delete.
    case deleteFaces
    /// `[02 F1 23 FF…]` on 0x0002, fire-and-forget, no file manager involved —
    /// but the watch refuses it unless the session is authenticated, so it
    /// needs the right auth key. Wipes pairing and everything else.
    case factoryReset
    /// Stream a DFU image. Last resort, and the one least likely to fit in the
    /// window — see `reflashRescue`.
    case reflashFirmware
}

enum WatchfaceRescue {
    private static let armedKey = "rescueDeleteAllWatchfacesOnConnect"
    private static let modeKey = "rescueMode"
    private static let targetKey = "rescueTargetFace"
    private static let firmwareKey = "rescueFirmwarePath"

    /// Watchdog per request while rescuing. Much tighter than the normal 12–20 s:
    /// the whole window between two reboots is under a minute, so a request the
    /// watch will never answer must fail fast enough to leave room for the next.
    static let requestTimeout: TimeInterval = 6
    /// Unwedging is a one-frame exchange — if it doesn't answer promptly it
    /// isn't going to, and the window is better spent on the deletes.
    static let closeTimeout: TimeInterval = 3
    /// A whole `.wapp` in each direction, so this one gets real time — but
    /// still less than a reboot cycle.
    static let transferTimeout: TimeInterval = 20
    /// The watchdog re-arms on every packet written, so this is the wait
    /// *after* the last packet is out. A healthy watch commits in well under a
    /// second; a crashing one never will, and every second spent waiting for it
    /// is a second of the window burned.
    static let commitTimeout: TimeInterval = 6

    static var mode: WatchfaceRescueMode {
        get {
            UserDefaults.standard.string(forKey: modeKey)
                .flatMap(WatchfaceRescueMode.init(rawValue:)) ?? .overwriteFace
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// The re-labelled replacement built in an earlier window, per watch. The
    /// watch is only reachable for seconds at a time, so a retry spends them on
    /// the upload instead of downloading the donor face again. In memory only:
    /// it is worth nothing once the app restarts, since the rescue re-lists and
    /// rebuilds it anyway.
    private static let stagedLock = NSLock()
    private nonisolated(unsafe) static var staged: [UUID: (target: String, wapp: Data)] = [:]

    static func stagedReplacement(for watchID: UUID, target: String) -> Data? {
        stagedLock.withLock {
            guard let entry = staged[watchID], entry.target == target else { return nil }
            return entry.wapp
        }
    }

    static func stageReplacement(_ wapp: Data, for watchID: UUID, target: String) {
        stagedLock.withLock { staged[watchID] = (target, wapp) }
    }

    static var isArmed: Bool {
        get { UserDefaults.standard.bool(forKey: armedKey) }
        set { UserDefaults.standard.set(newValue, forKey: armedKey) }
    }

    /// The face `overwriteFace` writes over — the one the user knows is bad.
    static var targetFace: String? {
        get { UserDefaults.standard.string(forKey: targetKey) }
        set { UserDefaults.standard.set(newValue, forKey: targetKey) }
    }

    /// Where the DFU image picked at arming time was copied to. Stored as a
    /// filename, resolved under Application Support, so it survives the
    /// security-scoped URL going away and container paths changing between
    /// launches.
    static var firmwareURL: URL? {
        get {
            guard let name = UserDefaults.standard.string(forKey: firmwareKey) else { return nil }
            return firmwareDirectory?.appendingPathComponent(name)
        }
        set { UserDefaults.standard.set(newValue?.lastPathComponent, forKey: firmwareKey) }
    }

    static var firmwareDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
    }

    /// Clears everything an armed rescue holds, including the staged image.
    static func disarm() {
        if let url = firmwareURL { try? FileManager.default.removeItem(at: url) }
        isArmed = false
        targetFace = nil
        UserDefaults.standard.removeObject(forKey: firmwareKey)
        stagedLock.withLock { staged.removeAll() }
    }
}

/// How much of an upload made it onto the wire. Written from `bleQueue` via the
/// request's progress callback, read from the rescue's task once it fails — the
/// difference between "the watch never took the data" and "it took all of it
/// and never acknowledged the commit", which are opposite situations.
private final class UploadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var highWaterMark = 0.0

    func record(_ fraction: Double) {
        lock.withLock { highWaterMark = max(highWaterMark, fraction) }
    }

    var fraction: Double { lock.withLock { highWaterMark } }
}

extension WatchConnection {
    /// Deletes every installed watchface as fast as the protocol allows.
    /// Best effort throughout: each delete is independent, so one failing (or
    /// the watch rebooting under us) still leaves the rest attempted, and
    /// whatever is left is picked up on the next connection.
    func runWatchfaceRescue() async {
        try? await WatchSession.exclusive(for: connectionTokenSync()) {
            let mode = WatchfaceRescue.mode
            self.addLog("⛑ Watchface rescue armed (\(mode.rawValue)) — recovering before init")
            // Another connected watch is not blocked by this watch's session
            // gate (they are per watch, deliberately — and taking a second
            // watch's gate here could deadlock against a fan-out that already
            // holds it), so its traffic shares the radio with a rescue that
            // only gets seconds per reboot cycle. Say so rather than silently
            // competing.
            let others = self.fleet.allConnections()
                .filter { $0.watchID != self.watchID && $0.connectionTokenSync() != nil }
            if !others.isEmpty {
                let roster = WatchRegistry.knownWatchesSync()
                let names = others.map { other in
                    roster.first(where: { $0.id == other.watchID })?.name ?? "another watch"
                }
                self.addLog("⛑ Rescue: \(names.joined(separator: ", ")) also connected — " +
                            "turn “Keep connected” off for it to give this watch the radio")
            }
            switch mode {
            case .deleteFaces: await self.deleteFacesRescue()
            case .overwriteFace: await self.overwriteFaceRescue()
            case .factoryReset: await self.factoryResetRescue()
            case .reflashFirmware: await self.reflashRescue()
            }
        }
    }

    // MARK: - Mode: delete every face

    private func deleteFacesRescue() async {
        guard let token = WatchSession.connectionToken else { return }
        let faces: [InstalledApp]
        do {
            faces = try await listWatchfacesForRescue()
        } catch {
            addLog("⛑ Rescue: listing failed (\(error.localizedDescription)) — retrying on next connect")
            return
        }
        guard !faces.isEmpty else {
            await finishRescue(remaining: [], keeping: nil)
            return
        }
        let activeName = await MainActor.run { self.activeWatchfaceName }
        let keeper = fallbackFace(from: faces, active: activeName)

        // Step 1: end any file session left open on the watch. Evidence for
        // this being the actual blocker: a file put's *open* is acked and its
        // data streams fine, then the commit never comes — and after that the
        // watch answers nothing at all for a delete, while reads still work.
        // That is the wedged-socket state the put path warns about, and a close
        // (GB's FileCloseRequest, opcode 0x09) is the documented way out.
        // Cheap, harmless when nothing is stuck, so it runs first every time.
        for handle in [FossilFileHandle.appCode.rawValue] + faces.map(\.fullHandle) {
            guard validatesConnectionToken(token) else { return }
            let close = FileCloseRequest(handle: handle)
            close.idleTimeoutOverride = WatchfaceRescue.closeTimeout
            if (try? await run(close)) != nil {
                addLog(String(format: "⛑ Rescue: closed a stuck file session on 0x%04X", Int(handle)))
            }
        }

        // Step 2: delete every face except the one meant to survive — the
        // suspect first (see `deleteOrder`). Deleting the last face too would
        // leave the watch with no theme at all, which is its own crash.
        //
        // The theme switch that used to run here is gone: `selected_theme` is a
        // JSON put the *watchface engine* has to consume, and that engine is
        // precisely what is crashing — the put opened, streamed and then hung
        // for the full 30 s window, wedging the JSON channel on the way out.
        // Nothing that depends on the engine can be part of a rescue.
        let targets = deleteOrder(faces: faces, active: activeName, keeping: keeper)
        addLog("⛑ Rescue: \(targets.count) watchface(s) to delete: \(targets.map(\.name).joined(separator: ", "))")
        for face in targets {
            guard validatesConnectionToken(token) else {
                addLog("⛑ Rescue: link dropped — resuming on next connect")
                return
            }
            do {
                let delete = FileDeleteRequest(handle: face.fullHandle)
                delete.idleTimeoutOverride = WatchfaceRescue.requestTimeout
                try await run(delete)
                addLog("⛑ Rescue: deleted \(face.name)")
            } catch {
                addLog(String(format: "⛑ Rescue: deleting %@ (handle 0x%04X) failed: %@",
                              face.name, Int(face.fullHandle), error.localizedDescription))
            }
        }
        // Re-list rather than trusting the deletes: the file the watch boots
        // from is the only thing that decides whether this worked.
        let remaining = (try? await listWatchfacesForRescue()) ?? faces
        await finishRescue(remaining: remaining, keeping: keeper?.name)
        if !targets.isEmpty, remaining.count == faces.count {
            addLog("⛑ Rescue: this firmware is dropping deletes entirely — " +
                   "next step is “Overwrite a face”, then Factory reset")
        }
    }

    // MARK: - Mode: overwrite the failing face's slot

    /// Installs a healthy face under the broken face's identifier. This is the
    /// step that recovered a real wedged watch, and the sequence is shaped by
    /// what that watch actually did:
    ///
    /// 1. List the apps — a read, so it answers even mid-crash-loop.
    /// 2. If the target is gone, the previous window already won: disarm.
    /// 3. Download a stock face off the *same watch* (bytes known-good for this
    ///    firmware — the broken face may well have come from our own bundle)
    ///    and re-label it with the target's identifier. Kept in memory, so a
    ///    retry spends its seconds uploading instead of downloading again.
    /// 4. Install it on the APP_CODE handle — the only handle that accepts a
    ///    put; the watch assigns the slot by the identifier inside the file.
    ///
    /// **The commit is not expected to arrive**, and that is not a failure. To
    /// install a face under a name that already exists, the watch's app manager
    /// must clear the old one first — the delete it refuses to do for us, it
    /// will do for itself. It rebuilds its app storage around that, drops the
    /// side-loaded faces, and the link goes with it. The bad face is gone at
    /// the next connection, the theme pointer no longer resolves, and the watch
    /// falls back to a stock face — which is exactly how the loop breaks. So a
    /// fully-streamed upload with no commit stays armed for one more window to
    /// *verify*, rather than reporting a failure and escalating.
    private func overwriteFaceRescue() async {
        guard let token = WatchSession.connectionToken else { return }
        guard let targetName = WatchfaceRescue.targetFace else {
            addLog("⛑ Rescue: no face chosen to replace — disarming")
            WatchfaceRescue.disarm()
            return
        }
        let faces: [InstalledApp]
        do {
            faces = try await listWatchfacesForRescue()
        } catch {
            addLog("⛑ Rescue: listing failed (\(error.localizedDescription)) — retrying on next connect")
            return
        }
        guard let victim = faces.first(where: { $0.name == targetName }) else {
            WatchfaceRescue.disarm()
            addLog("⛑ Rescue complete — \(targetName) is no longer on the watch")
            await MainActor.run {
                self.activeWatchfaceImage = nil
                ToastCenter.shared.success(String(
                    localized: "\(targetName) is gone — the watch should be stable again"))
            }
            return
        }

        // A retry already carries the replacement; skip straight to the upload.
        var replacement = WatchfaceRescue.stagedReplacement(for: watchID, target: targetName)
        if replacement == nil {
            replacement = await buildReplacement(for: victim, from: faces, token: token)
        }
        guard let replacement, validatesConnectionToken(token) else { return }

        let progress = UploadProgress()
        do {
            addLog("⛑ Rescue: installing \(replacement.count) bytes as \(victim.name)")
            let put = FilePutRawRequest(handle: FossilFileHandle.appCode.rawValue, file: replacement)
            put.idleTimeoutOverride = WatchfaceRescue.commitTimeout
            put.onProgress = { progress.record($0) }
            try await run(put)
        } catch {
            guard progress.fraction >= 1.0 else {
                addLog(String(format: "⛑ Rescue: upload stalled at %.0f%% (%@) — retrying next connection",
                              progress.fraction * 100, error.localizedDescription))
                return
            }
            // The whole file is on the watch and the commit never came: the
            // expected outcome on a crash-looping watch, and the one that
            // recovers it. Stay armed only to confirm at the next connection.
            addLog("⛑ Rescue: whole file delivered, no commit — the watch is rebuilding its " +
                   "app storage. Confirming on the next connection.")
            return
        }
        WatchfaceRescue.disarm()
        addLog("⛑ Rescue complete — \(victim.name) now carries working code")
        _ = try? await listWatchfacesForRescue()
        await MainActor.run {
            self.activeWatchfaceImage = nil
            ToastCenter.shared.success(String(
                localized: "Reinstalled \(victim.name) with working code"))
        }
    }

    /// Downloads a healthy face and re-labels it as `victim`, staging the
    /// result so a later window can go straight to the upload.
    private func buildReplacement(for victim: InstalledApp, from faces: [InstalledApp],
                                  token: WatchConnectionToken) async -> Data? {
        guard let donor = faces.first(where: {
            $0.name != victim.name && $0.name != "Dashboard" && !looksSelfBuilt($0.name)
        }) else {
            addLog("⛑ Rescue: no healthy face on the watch to copy from — disarming")
            WatchfaceRescue.disarm()
            return nil
        }
        // Both slots first: a session left open by an earlier attempt makes the
        // watch refuse the next open, and this costs a fraction of a second.
        for handle in [victim.fullHandle, donor.fullHandle] {
            guard validatesConnectionToken(token) else { return nil }
            let close = FileCloseRequest(handle: handle)
            close.idleTimeoutOverride = WatchfaceRescue.closeTimeout
            _ = try? await run(close)
        }
        let wapp: Data
        do {
            addLog("⛑ Rescue: reading \(donor.name) to reinstall as \(victim.name)")
            let get = FileGetRawRequest(handle: donor.fullHandle)
            get.idleTimeoutOverride = WatchfaceRescue.transferTimeout
            try await run(get)
            // `.wapp` headers always carry the fixed APP_CODE handle whatever
            // slot they live in, so validate against that, not the slot.
            wapp = try get.validatedFileData(expectedHandle: FossilFileHandle.appCode.rawValue)
        } catch {
            addLog("⛑ Rescue: reading \(donor.name) failed: \(error.localizedDescription)")
            return nil
        }
        do {
            let replacement = try WappBuilder.renamingIdentifier(in: wapp, to: victim.name)
            WatchfaceRescue.stageReplacement(replacement, for: watchID, target: victim.name)
            return replacement
        } catch {
            addLog("⛑ Rescue: could not re-label \(donor.name) as \(victim.name): \(error)")
            addLog("⛑ Rescue: \(donor.name) container — \(WappBuilder.containerSummary(wapp))")
            WatchfaceRescue.disarm()
            return nil
        }
    }

    // MARK: - Mode: factory reset

    /// One fire-and-forget frame on 0x0002 — no reply expected, no file manager
    /// involved, which is exactly why it is worth trying on a watch whose file
    /// manager has stopped answering. Wipes the watch, including its pairing
    /// and auth key, so the watch needs a full re-setup afterwards.
    private func factoryResetRescue() async {
        // "Unlikely error" on the 0x0002 write is an ATT error code coming
        // *back from the watch* — it received the frame and refused it, which
        // it has every reason to do for a wipe on an unauthenticated session.
        // The rest of the rescue needs no authentication, so this is the one
        // step that tries it first; if the key is wrong the log now says so
        // instead of leaving an unexplained refusal.
        if KeychainStore.loadKey(for: watchID) != nil {
            do {
                try await authenticate()
                addLog("⛑ Rescue: authenticated — sending the reset on a trusted session")
            } catch {
                addLog("⛑ Rescue: authentication failed (\(error.localizedDescription)) — " +
                       "a wipe is likely to be refused; the stored auth key may be wrong")
                await MainActor.run {
                    ToastCenter.shared.error(String(
                        localized: "The stored auth key doesn't match this watch — a factory reset needs the right key"))
                }
            }
        } else {
            addLog("⛑ Rescue: no auth key stored — a wipe is likely to be refused")
        }
        do {
            try await run(FactoryResetRequest())
            WatchfaceRescue.disarm()
            addLog("⛑ Rescue: factory reset sent — the watch is wiping and rebooting")
            await MainActor.run {
                ToastCenter.shared.success(String(
                    localized: "Factory reset sent — set the watch up again once it reboots"))
            }
        } catch {
            addLog("⛑ Rescue: factory reset failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Mode: reflash firmware

    /// Streams the DFU image staged when the rescue was armed. This is the
    /// least likely of the four to succeed on a watch that reboots every ~60 s:
    /// a Hybrid HR image is around a megabyte and takes minutes over BLE, and a
    /// reboot part-way through leaves the watch mid-flash. It is here because
    /// it is the last thing left to try, not because the odds are good — the
    /// battery guard in `installFirmware` still applies.
    private func reflashRescue() async {
        guard let url = WatchfaceRescue.firmwareURL,
              let firmware = try? Data(contentsOf: url) else {
            addLog("⛑ Rescue: no firmware image staged — disarming")
            WatchfaceRescue.disarm()
            return
        }
        addLog("⛑ Rescue: flashing \(FirmwareReader.version(firmware) ?? "?") " +
               "(\(firmware.count) bytes) — this needs minutes without a reboot")
        do {
            try await installFirmware(firmware)
            WatchfaceRescue.disarm()
            await MainActor.run {
                ToastCenter.shared.success(String(
                    localized: "Firmware transferred — the watch is installing it"))
            }
        } catch {
            addLog("⛑ Rescue: flashing failed: \(error.localizedDescription) — staying armed")
        }
    }

    /// A watchface built by this app carries the design's UUID as its
    /// identifier when it was never named ("C265D7C9-2666-46"), so a
    /// UUID-shaped name is a face the user built and pushed — by far the most
    /// likely thing to have broken a watch that was fine before.
    private func looksSelfBuilt(_ name: String) -> Bool {
        name.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}"#, options: .regularExpression) != nil
    }

    /// The one face left installed, so the watch still has something to draw.
    /// Never the active (suspect) one, never a self-built one, and never
    /// `Dashboard` — the suffix rule counts that as a face when it is really
    /// the stock dashboard app, so keeping it could mean keeping *no* face.
    ///
    /// Matching against `BundledFaces` is only a preference, not a
    /// requirement: those names come from the `.wapp` display name ("Regence")
    /// while the watch lists identifiers ("regenceFace"), so the match usually
    /// misses. It was the sole criterion before, which is how the previous run
    /// picked the self-built face — the suspect — as the one to keep.
    private func fallbackFace(from faces: [InstalledApp], active: String?) -> InstalledApp? {
        let candidates = faces.filter {
            $0.name != active && $0.name != "Dashboard" && !looksSelfBuilt($0.name)
        }
        return candidates.first { BundledFaces.matching(name: $0.name) != nil } ?? candidates.first
    }

    /// Suspect first — the face the watch loaded at boot if we know it,
    /// otherwise the self-built ones — so the likely crasher goes in the window
    /// we actually have. The keeper is never a target.
    private func deleteOrder(faces: [InstalledApp], active: String?,
                             keeping keeper: InstalledApp?) -> [InstalledApp] {
        let targets = faces.filter { $0.name != keeper?.name }
        let suspects = targets.filter { $0.name == active || looksSelfBuilt($0.name) }
        return suspects + targets.filter { face in !suspects.contains { $0.name == face.name } }
    }

    /// Reads the app-code file with rescue timeouts and publishes the listing,
    /// returning just the watchfaces. Same two requests as
    /// `refreshInstalledApps`, which can't be reused here because its requests
    /// carry the normal (far too patient) watchdogs.
    private func listWatchfacesForRescue() async throws -> [InstalledApp] {
        let lookup = FileLookupRequest(major: FossilFileHandle.appCode.major)
        lookup.idleTimeoutOverride = WatchfaceRescue.requestTimeout
        try await run(lookup)
        if lookup.fileEmpty {
            await MainActor.run { self.installedApps = [] }
            return []
        }
        guard let handle = lookup.resolvedHandle else { return [] }
        let get = FileGetRawRequest(handle: handle)
        get.idleTimeoutOverride = WatchfaceRescue.requestTimeout
        try await run(get)
        let apps = InstalledApp.parseList(fromRawFile: try get.validatedFileData())
        await MainActor.run { self.installedApps = apps }
        addLog("⛑ Rescue: installed apps: \(apps.map(\.name).joined(separator: ", "))")
        return apps.filter(\.isWatchface)
    }

    /// Done when nothing is left but the face the watch was switched onto —
    /// that one is deliberately kept, a watch with no theme at all is its own
    /// crash. Anything else still there means another window is needed.
    private func finishRescue(remaining: [InstalledApp], keeping keeper: String?) async {
        let leftover = remaining.filter { $0.name != keeper }
        guard leftover.isEmpty else {
            addLog("⛑ Rescue: \(leftover.count) watchface(s) still on the watch " +
                   "(\(leftover.map(\.name).joined(separator: ", "))) — staying armed")
            return
        }
        WatchfaceRescue.disarm()
        if let keeper {
            addLog("⛑ Rescue complete — only \(keeper) left on the watch")
        } else {
            addLog("⛑ Rescue complete — no watchfaces left on the watch")
            if let watchID = WatchSession.connectionToken?.watchID {
                UserDefaults.standard.removeObject(
                    forKey: WatchScoped.key(.activeWatchfaceName, watchID: watchID))
            }
        }
        await MainActor.run {
            if keeper == nil {
                self.activeWatchfaceName = nil
                self.activeWatchfaceImage = nil
            }
            ToastCenter.shared.success(keeper.map {
                String(localized: "Watchfaces removed — \($0) is now on the watch")
            } ?? String(localized: "All watchfaces removed — install a known-good face"))
        }
    }
}
