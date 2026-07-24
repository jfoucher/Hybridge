import Foundation
@preconcurrency import CoreBluetooth
import UIKit

/// A deliberately narrow one-way transfer into a serial dispatch queue. This
/// avoids claiming that every mutable FossilRequest subclass is generally
/// Sendable; WatchConnection is the only owner after the transfer.
private struct QueueTransfer<Value>: @unchecked Sendable {
    let value: Value
}

/// One watch's live BLE session: its peripheral, characteristics, connection
/// token, the serialized request queue and all the per-watch published state.
/// Owns the `CBPeripheralDelegate` for its own peripheral; the CoreBluetooth
/// *central* and the connect/reconnect lifecycle live in `WatchFleet`, which
/// drives this object through the `attach`/`handle…`/`reset…` hooks.
///
/// All CoreBluetooth and request-queue work happens on the fleet's shared
/// `bleQueue`; published state is updated on main. The explicit unchecked
/// conformance documents that queue-isolation boundary for DispatchQueue's
/// @Sendable closures.
final class WatchConnection: NSObject, ObservableObject, @unchecked Sendable {
    /// Stable identity — the peripheral UUID — known before a token exists.
    let watchID: UUID
    /// The fleet that owns the central and created this connection. `unowned`
    /// because the fleet outlives every connection it vends.
    unowned let fleet: WatchFleet
    /// Shared with every other connection and the fleet: it is a
    /// synchronization domain, not a per-watch throughput bottleneck.
    let bleQueue: DispatchQueue

    @Published var connectionState: ConnectionState = .disconnected {
        didSet { connectionObservationDate = Date() }
    }
    @Published private(set) var connectionObservationDate = Date()
    @Published var batteryLevel: Int?
    /// Updated only when a battery value is actually observed. The setter is
    /// module-internal because the family-specific WatchConnection extensions
    /// publish configuration reads from their own source files.
    @Published var batteryObservationDate: Date?
    @Published var firmwareVersion: String?
    @Published var modelNumber: String?
    /// Hardware family of the connected watch, detected from the firmware
    /// string (GB: WatchAdapterFactory). `.unknown` until 2A26 is read.
    @Published var watchKind: WatchKind = .unknown
    @Published var installedApps: [InstalledApp] = []
    @Published var isAuthenticated = false
    /// BLE bond status as reported by the watch (nil until checked). Bonding
    /// unlocks iOS-native ANCS/AMS on the watch side.
    @Published var isDevicePaired: Bool?
    /// True while a freshly added watch is buzzing and waiting for the user to
    /// press its middle button to confirm adoption — the same physical check
    /// the official app requires, so you can't accidentally add someone else's
    /// nearby watch. Drives the confirmation overlay.
    @Published var awaitingAdoptionConfirm = false
    @Published var uploadProgress: Double?
    @Published var liveHeartRate: Int?
    @Published var liveHeartRateActive = false
    /// Step count as reported by the watch's configuration file.
    @Published var watchStepCount: Int?
    /// Name of the last watchface we activated on this watch (persisted per
    /// watch; the protocol has no way to ask the watch which face is showing).
    @Published var activeWatchfaceName: String?
    /// Background of the active watchface, downloaded from the watch itself
    /// and decoded from its .wapp (GB: FossilFileReader.getBackground).
    @Published var activeWatchfaceImage: UIImage?

    private var peripheral: CBPeripheral?
    private let connectionIdentityLock = NSLock()
    nonisolated(unsafe) private var connectionGeneration: UInt64 = 0
    nonisolated(unsafe) private var connectionTokenStorage: WatchConnectionToken?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    /// Vendor characteristics whose notify-enable is still unconfirmed.
    private var pendingNotifyChars: Set<CBUUID> = []
    /// Guards against kicking off the init sequence more than once per connection.
    private var sessionStarted = false
    /// Guards against dispatching the kind-specific app-level init more than
    /// once per connection (it runs from the firmware read, which a manual
    /// re-read could otherwise trigger again).
    private var initDispatched = false

    var fileVersions = DeviceFileVersions()

    // Request queue (all mutations on bleQueue).
    private var currentRequest: FossilRequest?
    private var currentContinuation: CheckedContinuation<Void, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var currentRequestStarted = Date()

    // File packet streaming state (on bleQueue).
    private var pendingPackets: [Data] = []
    private var nextPacketIndex = 0
    private var packetWriteType: CBCharacteristicWriteType = .withResponse

    /// Set when the user picks a watch from the scan list, so the next init
    /// triggers the iOS pairing dialog automatically if the watch isn't
    /// bonded yet. Never set on auto-reconnects — the dialog would pop up
    /// unprompted. Consumed by initializeWatch().
    var autoPairOnNextInit = false

    /// Set only when the picked watch was NOT already in the roster, so init
    /// runs the vibrate-and-press adoption gate (and forgets the watch again
    /// if it isn't confirmed). Re-picking an already-added watch is just a
    /// reconnect and skips the gate. Consumed by the init sequences.
    var adoptingNewWatch = false

    /// Dedup index of the last raw button-press frame (requestType 0x08) —
    /// the watch repeats the frame, GB dedups the same way.
    private var lastButtonFrameIndex = -1

    /// True while the user wants a connection maintained (auto-reconnect).
    /// Read by the fleet's disconnect handler to decide whether to re-arm.
    var userWantsConnection = false

    /// BLE-queue trust mirrors used for watch-originated phone actions.
    private var sessionReady = false
    private var sessionAuthenticated = false
    private var connectedKind: WatchKind = .unknown

    /// Throttles `periodicMaintenance` so the foreground trigger doesn't
    /// re-hit the watch on every app switch (read/written on main).
    var lastMaintenanceDate = Date.distantPast

    /// True while this connection's family init sequence is running. Per
    /// connection (was a single global flag): a maintenance/quiet-hours caller
    /// checks it to avoid piling onto a running init without taking the
    /// session. Lock-guarded — read from bleQueue, main and task executors.
    var isInitializing: Bool {
        get { initFlagLock.withLock { isInitializingStorage } }
        set { initFlagLock.withLock { isInitializingStorage = newValue } }
    }
    private let initFlagLock = NSLock()
    nonisolated(unsafe) private var isInitializingStorage = false

    init(fleet: WatchFleet, watchID: UUID) {
        self.fleet = fleet
        self.watchID = watchID
        self.bleQueue = fleet.bleQueue
        super.init()
        activeWatchfaceName = UserDefaults.standard
            .string(forKey: WatchScoped.key(.activeWatchfaceName, watchID: watchID))
    }

    // MARK: - Logging

    func addLog(_ text: String) { fleet.addLog(text, watchID: watchID) }

    // MARK: - Connection token

    func connectionTokenSync() -> WatchConnectionToken? {
        connectionIdentityLock.withLock { connectionTokenStorage }
    }

    func validatesConnectionToken(_ token: WatchConnectionToken?) -> Bool {
        guard let token, let current = connectionTokenSync() else { return false }
        return token.authorizes(current)
    }

    /// On bleQueue. Every attachment/re-attachment gets a fresh generation.
    private func establishConnectionToken(for peripheral: CBPeripheral) {
        let knownKind = WatchRegistry.knownWatchesSync()
            .first(where: { $0.id == peripheral.identifier })?.kind ?? .unknown
        connectionIdentityLock.withLock {
            connectionGeneration &+= 1
            connectionTokenStorage = WatchConnectionToken(
                watchID: peripheral.identifier,
                peripheralID: peripheral.identifier,
                generation: connectionGeneration,
                kind: knownKind)
        }
        connectedKind = knownKind
        sessionReady = false
        sessionAuthenticated = false
    }

    /// On bleQueue. Invalidating first ensures old queued work fails closed.
    private func invalidateConnectionToken() {
        connectionIdentityLock.withLock {
            connectionGeneration &+= 1
            connectionTokenStorage = nil
        }
        sessionReady = false
        sessionAuthenticated = false
        connectedKind = .unknown
    }

    private func updateConnectionKind(_ kind: WatchKind) {
        connectionIdentityLock.withLock {
            guard let token = connectionTokenStorage else { return }
            connectionTokenStorage = WatchConnectionToken(
                watchID: token.watchID, peripheralID: token.peripheralID,
                generation: token.generation, kind: kind)
        }
        connectedKind = kind
    }

    func markSessionReady(for token: WatchConnectionToken) async -> Bool {
        await withCheckedContinuation { continuation in
            bleQueue.async {
                guard self.validatesConnectionToken(token) else {
                    continuation.resume(returning: false)
                    return
                }
                self.sessionReady = true
                DispatchQueue.main.async { self.connectionState = .ready }
                continuation.resume(returning: true)
            }
        }
    }

    // MARK: - Fleet-driven lifecycle hooks (all on bleQueue)

    /// The peripheral this connection currently owns (nil while disconnected).
    /// The fleet reads it to compare identifiers and to cancel/reconnect.
    var attachedPeripheral: CBPeripheral? { peripheral }

    /// Bind a peripheral to this connection: take a fresh token and become its
    /// delegate. The fleet calls this before `central.connect`.
    func attach(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        establishConnectionToken(for: peripheral)
        peripheral.delegate = self
    }

    func setConnecting() { DispatchQueue.main.async { self.connectionState = .connecting } }
    func setInitializing() { DispatchQueue.main.async { self.connectionState = .initializing } }
    func setBluetoothOff() { DispatchQueue.main.async { self.connectionState = .bluetoothOff } }

    /// A fresh connection succeeded — begin service discovery.
    func handleConnected() {
        sessionStarted = false
        pendingNotifyChars = []
        DispatchQueue.main.async { self.connectionState = .initializing }
        peripheral?.discoverServices(nil)
    }

    /// The pending connect failed. Clears the peripheral and publishes failure.
    func handleConnectFailed(_ error: Error?) {
        peripheral = nil
        invalidateConnectionToken()
        DispatchQueue.main.async {
            self.connectionState = .failed(
                error?.localizedDescription ?? String(localized: "connection failed"))
        }
    }

    /// The link dropped. Clears all per-connection state and returns whether
    /// the fleet should re-arm the pending connect (the user still wants it).
    func resetForDisconnect() -> Bool {
        failCurrentRequest(FossilError.notConnected)
        let shouldReconnect = userWantsConnection
        invalidateConnectionToken()
        peripheral = nil
        characteristics = [:]
        pendingNotifyChars = []
        sessionStarted = false
        initDispatched = false
        DispatchQueue.main.async {
            self.connectionState = shouldReconnect ? .connecting : .disconnected
            self.isAuthenticated = false
            self.batteryLevel = nil
            self.batteryObservationDate = nil
            self.installedApps = []
        }
        return shouldReconnect
    }

    /// Tears the session down (a switch or forget). Clears every
    /// per-connection field and resets published state. `userWantsConnection`
    /// is cleared first so a late `didDisconnect` can't re-arm reconnect. The
    /// fleet cancels the actual BLE link (it owns the central).
    func resetForTeardown() {
        invalidateConnectionToken()
        userWantsConnection = false
        failCurrentRequest(FossilError.notConnected)
        peripheral = nil
        characteristics = [:]
        pendingNotifyChars = []
        sessionStarted = false
        initDispatched = false
        pendingPackets = []
        fileVersions = DeviceFileVersions()
        autoPairOnNextInit = false
        adoptingNewWatch = false
        lastButtonFrameIndex = -1
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.awaitingAdoptionConfirm = false
            self.isAuthenticated = false
            self.isDevicePaired = nil
            self.batteryLevel = nil
            self.batteryObservationDate = nil
            self.firmwareVersion = nil
            self.modelNumber = nil
            self.watchKind = .unknown
            self.installedApps = []
            self.watchStepCount = nil
            self.liveHeartRate = nil
            self.liveHeartRateActive = false
            self.uploadProgress = nil
            self.activeWatchfaceImage = nil
        }
    }

    /// Cancels an in-flight adoption confirmation (the phone-side "Cancel" on
    /// the buzz-and-press overlay). Fails only the confirm request so its
    /// `run` throws and the init sequence forgets the watch — a no-op if some
    /// other request happens to be in flight. On bleQueue.
    func cancelAdoptionConfirmIfPending() {
        guard currentRequest is ConfirmOnDeviceRequest
                || currentRequest is QConfirmOnDeviceRequest else { return }
        failCurrentRequest(FossilError.cancelled)
    }

    /// Undoes a freshly-added watch that failed the adoption confirmation:
    /// tells the user why, then forgets it so nothing was actually added
    /// (drops the session, removes it from the roster, deletes its key).
    /// Called from the init sequences when `confirmAdoption` returns false.
    func abandonAdoption(_ id: UUID) async {
        addLog("Adoption not confirmed — removing \(id)")
        await MainActor.run {
            self.awaitingAdoptionConfirm = false
            ToastCenter.shared.error(String(
                localized: "Watch not added. Press the middle button while the watch vibrates to confirm it's yours."))
        }
        fleet.forget(id)
    }

    /// Reloads the persisted active-watchface name (after the roster's active
    /// watch changes, so the dashboard hero is right). On main.
    func reloadActiveWatchfaceName() {
        DispatchQueue.main.async {
            self.activeWatchfaceName = UserDefaults.standard
                .string(forKey: WatchScoped.key(.activeWatchfaceName, watchID: self.watchID))
        }
    }

    // MARK: - Request queue

    /// Run a request to completion. Serialized: awaits are chained by the
    /// callers (WatchActions), and a second concurrent call fails fast rather
    /// than interleaving packets on the wire.
    func run(_ request: FossilRequest) async throws {
        // Enforces the architecture's core invariant: every request must be
        // issued inside a `WatchSession.exclusive` block for *this* watch, so
        // no foreign request can land between two requests of someone else's
        // sequence. The task-local is read here in the caller's task context —
        // NOT inside the bleQueue closure below, where it would not propagate.
        //
        // In debug this traps at the offending call site. In release it must
        // NOT silently proceed: an unheld request can interleave into another
        // sequence's handshake and make an encrypted put encrypt under the
        // wrong AES-CTR IV — which on the notification-filter file writes a
        // config the watch reads as empty, silently dropping every
        // notification. Failing the one stray operation is strictly safer than
        // corrupting watch state, so we throw instead.
        guard WatchSession.holds(WatchSession.connectionToken?.watchID) else {
            assertionFailure("run(\(request.name)) issued without holding this watch's WatchSession.exclusive — see WatchSession.swift")
            throw FossilError.sessionNotHeld(request.name)
        }
        guard validatesConnectionToken(WatchSession.connectionToken) else {
            throw FossilError.staleConnection
        }
        let transferredRequest = QueueTransfer(value: request)
        let expectedToken = WatchSession.connectionToken
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bleQueue.async {
                let request = transferredRequest.value
                guard self.validatesConnectionToken(expectedToken) else {
                    continuation.resume(throwing: FossilError.staleConnection)
                    return
                }
                guard self.currentRequest == nil else {
                    let age = Int(Date().timeIntervalSince(self.currentRequestStarted))
                    continuation.resume(throwing: FossilError.unexpectedResponse("request already in flight (\(self.currentRequest!.name), \(age)s old)"))
                    return
                }
                guard let peripheral = self.peripheral, peripheral.state == .connected else {
                    continuation.resume(throwing: FossilError.notConnected)
                    return
                }
                guard let characteristic = self.characteristics[request.startUUID] else {
                    continuation.resume(throwing: FossilError.missingCharacteristic)
                    return
                }
                self.currentRequest = request
                self.currentContinuation = continuation
                self.currentRequestStarted = Date()
                self.addLog("→ \(request.name)")
                self.resetIdleWatchdog()

                do {
                    let data = try request.startData()
                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
                    if request.isFinished {
                        self.finishCurrentRequest()
                    }
                } catch {
                    self.failCurrentRequest(error)
                }
            }
        }
    }

    /// (Re)arm the idle watchdog for the current request. Called on start and
    /// on every sign of life (incoming frame, outgoing packet). On bleQueue.
    private func resetIdleWatchdog() {
        timeoutWorkItem?.cancel()
        guard let request = currentRequest else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, let stuck = self.currentRequest else { return }
            self.addLog("watchdog: no activity for \(Int(stuck.idleTimeout))s")
            self.failCurrentRequest(FossilError.timeout(stuck.name))
        }
        timeoutWorkItem = item
        bleQueue.asyncAfter(deadline: .now() + request.idleTimeout, execute: item)
    }

    // On bleQueue.
    private func finishCurrentRequest() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let continuation = currentContinuation
        if let request = currentRequest {
            addLog("✓ \(request.name)")
        }
        currentRequest = nil
        currentContinuation = nil
        pendingPackets = []
        DispatchQueue.main.async { self.uploadProgress = nil }
        continuation?.resume()
    }

    // On bleQueue.
    private func failCurrentRequest(_ error: Error) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let continuation = currentContinuation
        if let request = currentRequest {
            addLog("✗ \(request.name): \(error.localizedDescription)")
        }
        currentRequest = nil
        currentContinuation = nil
        pendingPackets = []
        DispatchQueue.main.async { self.uploadProgress = nil }
        continuation?.resume(throwing: error)
    }

    // MARK: - Session state helpers

    /// Marks the session authenticated after a successful key handshake. The
    /// session randoms themselves are not stored here: encrypted transfers use
    /// the values returned by `authenticate()` directly, which keeps the IV
    /// seed local to each operation and immune to a concurrent handshake
    /// swapping shared state (see WatchActions.authenticate).
    func markAuthenticated(for token: WatchConnectionToken) async -> Bool {
        await withCheckedContinuation { continuation in
            bleQueue.async {
                guard self.validatesConnectionToken(token) else {
                    continuation.resume(returning: false)
                    return
                }
                self.sessionAuthenticated = true
                DispatchQueue.main.async { self.isAuthenticated = true }
                continuation.resume(returning: true)
            }
        }
    }

    // MARK: - Characteristic access for reads

    func readCharacteristic(_ uuid: CBUUID) {
        bleQueue.async {
            guard let peripheral = self.peripheral,
                  let characteristic = self.characteristics[uuid] else { return }
            peripheral.readValue(for: characteristic)
        }
    }

    /// Routes a 0x05 action frame (GB: handleBackgroundCharacteristic /
    /// handleMusicRequest). HR watches drive media natively through iOS AMS
    /// once bonded — transport, metadata and system volume, for whatever app
    /// is playing, foreground or background — so the app takes no part in
    /// their music. Only the Q watches, which have no AMS client, route
    /// through MusicController. Q (GB parity): volume events (5/6) always act;
    /// 2/3/4 are music transport when a button is set to music control,
    /// otherwise the single/double/long presses of "forward to phone
    /// (multi-press)", mapped to the user's phone actions. On bleQueue.
    private func handleActionFrame(_ action: UInt8) {
        guard acceptsWatchOriginatedActions(),
              let token = connectionTokenSync(), token.kind == .fossilQ else { return }
        let functions = QButtonStore.functions ?? []
        if action >= 0x05 || functions.contains(.musicControl) {
            dispatchMusicAction(action, token: token)
            return
        }
        guard functions.contains(.forwardToPhoneMulti), (2...4).contains(action) else {
            dispatchMusicAction(action, token: token)
            return
        }
        let pressIndex = Int(action) - 2   // 2 single, 3 double, 4 long
        let mapped = QMultiPressStore.actions[pressIndex]
        addLog("Multi-press \(["single", "double", "long"][pressIndex]) → \(mapped.displayName)")
        switch mapped {
        case .none:
            break
        case .volumeUp:
            dispatchMusicAction(0x05, token: token)
        case .volumeDown:
            dispatchMusicAction(0x06, token: token)
        case .playPause:
            dispatchMusicAction(0x02, token: token)
        case .nextTrack:
            dispatchMusicAction(0x03, token: token)
        case .previousTrack:
            dispatchMusicAction(0x04, token: token)
        case .ringPhone:
            DispatchQueue.main.async {
                guard self.validatesConnectionToken(token) else { return }
                if PhoneFinder.shared.isRinging {
                    PhoneFinder.shared.stop()
                } else {
                    PhoneFinder.shared.start()
                }
            }
        }
    }

    private func dispatchMusicAction(_ action: UInt8, token: WatchConnectionToken) {
        DispatchQueue.main.async {
            MusicController.shared.performWatchAction(action, token: token)
        }
    }

    /// Acts on a 0x08 button frame from a Q watch according to the assigned
    /// function (GB: handleBackgroundCharacteristic): RING_PHONE toggles the
    /// find-my-phone ringer; FORWARD_TO_PHONE just surfaces the press.
    /// Buttons are 1/2/3 = top/middle/bottom. On bleQueue.
    private func handleQButtonPress(_ button: Int) {
        guard acceptsWatchOriginatedActions(),
              let token = connectionTokenSync(), token.kind == .fossilQ,
              let functions = QButtonStore.functions,
              (1...3).contains(button) else { return }
        switch functions[button - 1] {
        case .ringPhone:
            DispatchQueue.main.async {
                guard self.validatesConnectionToken(token) else { return }
                if PhoneFinder.shared.isRinging {
                    PhoneFinder.shared.stop()
                } else {
                    PhoneFinder.shared.start()
                }
            }
        case .forwardToPhone:
            DispatchQueue.main.async {
                guard self.validatesConnectionToken(token) else { return }
                ToastCenter.shared.success(String(localized: "Watch button pressed"))
            }
        default:
            break
        }
    }

    private func acceptsWatchOriginatedActions() -> Bool {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        let token = connectionTokenSync()
        let trusted = token.map { candidate in
            WatchRegistry.knownWatchesSync().contains {
                $0.id == candidate.watchID && $0.trusted != false
            }
        } ?? false
        return WatchActionAuthorization.allows(
            token: token,
            attachedPeripheralID: peripheral?.identifier,
            activeWatchID: WatchRegistry.activeWatchIDSync(),
            trusted: trusted,
            sessionReady: sessionReady,
            sessionAuthenticated: sessionAuthenticated,
            connectedKind: connectedKind)
    }

    func acknowledgeMediaAction(_ action: UInt8, token: WatchConnectionToken) {
        bleQueue.async {
            guard self.validatesConnectionToken(token),
                  self.acceptsWatchOriginatedActions() else { return }
            self.write(Data([0x02, 0x05, action, 0x00]), to: FossilUUID.char0006)
        }
    }

    // MARK: - Waiting for a cold-launch connect chain

    /// Polls `condition` every `interval` until it's true or `timeout`
    /// elapses, returning the final state either way. Shared by
    /// BackgroundRefresher and the App Intents — both can wake the app cold
    /// and need to wait out state restoration → reconnect → family init.
    func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.5,
                   _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !Task.isCancelled else { return false }
            if await condition() { return true }
            do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
            catch { return false }
        }
        return await condition()
    }

    /// Waits for this watch to reach `.ready`.
    @discardableResult
    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        await waitUntil(timeout: timeout) { await MainActor.run { self.connectionState == .ready } }
    }

    /// Waits for the family init sequence to finish, so a caller that just
    /// observed `.ready` doesn't race the tail of init's own request queue.
    @discardableResult
    func waitUntilIdle(timeout: TimeInterval) async -> Bool {
        await waitUntil(timeout: timeout) { !self.isInitializing }
    }

    /// Toggle live heart-rate streaming (standard HR service, 2A37).
    func setLiveHeartRate(_ enabled: Bool) {
        bleQueue.async {
            guard let peripheral = self.peripheral,
                  let characteristic = self.characteristics[FossilUUID.heartRateMeasurement] else { return }
            peripheral.setNotifyValue(enabled, for: characteristic)
            DispatchQueue.main.async {
                self.liveHeartRateActive = enabled
                if !enabled { self.liveHeartRate = nil }
            }
        }
    }
}

// MARK: - RequestIO

extension WatchConnection: RequestIO {
    var maxFilePacketPayload: Int {
        guard let peripheral = attachedPeripheral else { return 19 }
        // Always size chunks from the without-response limit: it reflects the
        // real ATT MTU (mtu - 3). The with-response limit can report 512 by
        // assuming ATT long writes, which the watch firmware does not handle.
        let usable = peripheral.maximumWriteValueLength(for: .withoutResponse)

        return max(19, min(usable, 509) - 1)
    }

    func write(_ data: Data, to uuid: CBUUID) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard let peripheral = attachedPeripheral, let characteristic = characteristics[uuid] else { return }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    func writeFilePackets(_ packets: [Data]) {
        pendingPackets = packets
        nextPacketIndex = 0
        addLog("  streaming \(packets.count) packets to 3dda0004")
        sendNextPackets()
    }

    // On bleQueue. Drives the chunk stream with backpressure.
    private func sendNextPackets() {
        bleQueue.async { [self] in
            guard let peripheral = attachedPeripheral, let characteristic = characteristics[FossilUUID.char0004] else { return }
            guard nextPacketIndex < pendingPackets.count else { return }

            if packetWriteType == .withoutResponse {
                while nextPacketIndex < pendingPackets.count {
                    guard peripheral.canSendWriteWithoutResponse else { return }
                    peripheral.writeValue(pendingPackets[nextPacketIndex], for: characteristic, type: .withoutResponse)
                    nextPacketIndex += 1
                    reportPacketProgress()

                }
            } else {
                peripheral.writeValue(pendingPackets[nextPacketIndex], for: characteristic, type: .withResponse)
                nextPacketIndex += 1
                reportPacketProgress()
            }
        }

    }

    private func reportPacketProgress() {
        resetIdleWatchdog()
        let progress = Double(nextPacketIndex) / Double(max(pendingPackets.count, 1))
        currentRequest?.onProgress?(progress)
        if pendingPackets.count > 4 {
            DispatchQueue.main.async { self.uploadProgress = progress }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension WatchConnection: CBPeripheralDelegate {
    /// CoreBluetooth may finish callbacks that were already queued when a
    /// watch was switched or torn down. Reject them before they can mutate
    /// characteristics, request state, or dispatch a phone-side action.
    private func acceptsDelegateCallback(from peripheral: CBPeripheral) -> Bool {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard self.peripheral?.identifier == peripheral.identifier,
              let token = connectionTokenSync(),
              token.peripheralID == peripheral.identifier else {
            addLog("Ignored stale peripheral callback from \(peripheral.identifier)")
            return false
        }
        return true
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard acceptsDelegateCallback(from: peripheral) else { return }
        if let error {
            addLog("Service discovery failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.connectionState = .failed(String(localized: "service discovery failed"))
            }
            return
        }
        guard let services = peripheral.services else { return }
        addLog("Services: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard acceptsDelegateCallback(from: peripheral) else { return }
        if let error {
            addLog("Char discovery failed for \(service.uuid): \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for characteristic in chars {
            characteristics[characteristic.uuid] = characteristic
            // 0003/0005 use indications, the others notifications — same
            // subscribe call either way.
            if FossilUUID.vendorNotifyChars.contains(characteristic.uuid),
               !characteristic.properties.isDisjoint(with: [.notify, .indicate]) {
                pendingNotifyChars.insert(characteristic.uuid)
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        startSessionIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsDelegateCallback(from: peripheral) else { return }
        if let error {
            addLog("notify enable FAILED on \(characteristic.uuid.uuidString.prefix(8)): \(error.localizedDescription)")
        }
        pendingNotifyChars.remove(characteristic.uuid)
        startSessionIfReady()
    }

    /// Starts the app-level init once the vendor characteristics are found
    /// AND all notification subscriptions are confirmed — sending requests
    /// earlier can lose the watch's responses.
    private func startSessionIfReady() {
        // 0003/0004 (file protocol) must be subscribed on every family.
        // 0005 carries auth on the HR and must be subscribed there, but the
        // older Q watches only take raw vibration writes on it — require it
        // only when the characteristic itself claims notify/indicate.
        let char0005Ready: Bool = {
            guard let char = characteristics[FossilUUID.char0005] else { return true }
            return char.properties.isDisjoint(with: [.notify, .indicate]) || char.isNotifying
        }()
        guard !sessionStarted,
              pendingNotifyChars.isEmpty,
              let peripheral,
              let control = characteristics[FossilUUID.char0003], control.isNotifying,
              characteristics[FossilUUID.char0004]?.isNotifying == true,
              char0005Ready
        else { return }
        sessionStarted = true

        if let dataChar = characteristics[FossilUUID.char0004],
            dataChar.properties.contains(.writeWithoutResponse) {
            packetWriteType = .withoutResponse
        } else {
            packetWriteType = .withResponse
        }
        addLog("Session ready — mtu(withResponse)=\(peripheral.maximumWriteValueLength(for: .withResponse)) mtu(withoutResponse)=\(peripheral.maximumWriteValueLength(for: .withoutResponse)) packetWrites=\(packetWriteType == .withoutResponse ? "withoutResponse" : "withResponse")")

        if let battery = characteristics[FossilUUID.batteryLevel] {
            peripheral.readValue(for: battery)
        }
        if let firmware = characteristics[FossilUUID.firmwareRevision] {
            peripheral.readValue(for: firmware)
        }
        if let model = characteristics[FossilUUID.modelNumber] {
            peripheral.readValue(for: model)
        }
        NotificationCenter.default.post(name: .watchCharacteristicsReady, object: nil)
        // The app-level init depends on the watch family, which the firmware
        // string decides — it is dispatched from the 2A26 read callback. A
        // watch without a firmware characteristic can't be classified; fall
        // back to what the registry remembers (HR for pre-detection rosters).
        if characteristics[FossilUUID.firmwareRevision] == nil {
            addLog("No firmware characteristic — assuming \(WatchRegistry.activeKindSync().displayName)")
            dispatchInitForKind(WatchRegistry.activeKindSync(), firmware: nil)
        }
    }

    /// Kicks off the family-specific app-level init (on bleQueue), exactly
    /// once per connection. Runs directly (not from the UI) so background
    /// auto-reconnects re-initialize too; the UI only handles the HR
    /// missing-key case, prompted via .watchNeedsAuthKey.
    private func dispatchInitForKind(_ kind: WatchKind, firmware: String?) {
        guard sessionStarted, !initDispatched, let peripheral else { return }
        initDispatched = true
        switch kind {
        case .hybridHR, .unknown:
            if KeychainStore.loadKey(for: peripheral.identifier) != nil {
                Task { await self.initializeWatch() }
            } else {
                NotificationCenter.default.post(name: .watchNeedsAuthKey, object: nil)
            }
        case .fossilQ:
            Task { await self.initializeQWatch() }
        case .misfitQ:
            addLog("⚠️ Firmware \(firmware ?? "?") is Misfit-era (first-gen Q) — protocol not supported")
            DispatchQueue.main.async {
                self.connectionState = .failed(String(
                    localized: "first-generation Q watches (Misfit protocol) are not supported"))
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsDelegateCallback(from: peripheral) else { return }
        if let error {
            addLog("read/notify error on \(characteristic.uuid.uuidString.prefix(8)): \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case FossilUUID.batteryLevel:
            let level = Int(value.first ?? 0)
            DispatchQueue.main.async {
                self.batteryLevel = level
                self.batteryObservationDate = Date()
            }
        case FossilUUID.firmwareRevision:
            let version = String(data: value, encoding: .utf8) ?? ""
            let kind = WatchKind.detect(firmware: version)
            updateConnectionKind(kind)
            addLog("Firmware: \(version) → \(kind.displayName)")
            if let id = self.peripheral?.identifier {
                WatchRegistry.shared.updateKind(id, kind: kind, firmware: version)
            }
            DispatchQueue.main.async {
                self.firmwareVersion = version
                self.watchKind = kind
            }
            dispatchInitForKind(kind, firmware: version)
        case FossilUUID.modelNumber:
            let model = String(data: value, encoding: .utf8)
            if let model, let id = self.peripheral?.identifier {
                WatchRegistry.shared.updateModel(id, model: model)
            }
            DispatchQueue.main.async { self.modelNumber = model }
        case FossilUUID.char0006:
            guard acceptsWatchOriginatedActions() else {
                addLog("Ignored watch-originated action before trusted ready state")
                return
            }
            addLog("event 0006: \(value.count <= 64 ? value.hexString : "\(value.count) bytes")")
            // JSON request from the watch: [.., 0x01, eventId, json...]
            if value.count > 3, value.u8(at: 1) == 0x01 {
                let jsonData = value.slice(3, value.count - 3)
#if DEBUG
                if let json = String(data: jsonData, encoding: .utf8),
                   json.localizedCaseInsensitiveContains("homeassistant") {
                    HomeAssistantLog.print(
                        "BLE characteristic 3DDA0006 notification: frameBytes=\(value.count), " +
                        "eventID=\(value.u8(at: 2)), jsonBytes=\(jsonData.count)")
                }
#endif
                handleWatchJsonRequest(jsonData)
            } else if value.count == 4, value.u8(at: 1) == 0x05 {
                // Music transport (HR musicApp) or Q multi-press frame.
                handleActionFrame(value.u8(at: 3))
            } else if value.count == 12, value.u8(at: 1) == 0x08 {
                // Raw button-press frame (GB: QHYBRID_EVENT_BUTTON_PRESS).
                // The watch repeats it until superseded — dedup by index.
                let index = Int(value.u8(at: 2))
                let button = Int((value.u8(at: 9) >> 4) & 0xF)
                if index != lastButtonFrameIndex {
                    lastButtonFrameIndex = index
                    let names = ["?", "top", "middle", "bottom"]
                    addLog("Watch button press: \(names[button < names.count ? button : 0])")
                    handleQButtonPress(button)
                }
            }
        case FossilUUID.heartRateMeasurement:
            // Standard HR measurement: flags byte, then u8 or u16 bpm.
            guard value.count >= 2 else { return }
            let bpm = (value.u8(at: 0) & 0x01) != 0 && value.count >= 3
                ? Int(value.u16LE(at: 1))
                : Int(value.u8(at: 1))
            DispatchQueue.main.async { self.liveHeartRate = bpm }
        default:
            guard let request = currentRequest else {
                addLog("  (no request in flight — frame ignored)")
                return
            }
            resetIdleWatchdog()
            do {
                try request.handle(uuid: characteristic.uuid, value: value, io: self)
                if request.isFinished {
                    finishCurrentRequest()
                }
            } catch {
                failCurrentRequest(error)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsDelegateCallback(from: peripheral) else { return }
        if let error {
            addLog("write FAILED on \(characteristic.uuid.uuidString.prefix(8)): \(error.localizedDescription)")
            failCurrentRequest(error)
            return
        }
        if characteristic.uuid == FossilUUID.char0004, packetWriteType == .withResponse {
            sendNextPackets()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard acceptsDelegateCallback(from: peripheral) else { return }
        sendNextPackets()
    }
}

extension Notification.Name {
    static let watchCharacteristicsReady = Notification.Name("watchCharacteristicsReady")
    /// Posted when the connected watch turns out to be an HR without a
    /// stored auth key — the UI answers with the key-entry sheet.
    static let watchNeedsAuthKey = Notification.Name("watchNeedsAuthKey")
}
