import Foundation
@preconcurrency import CoreBluetooth
import os.log
import UIKit

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

struct DiscoveredWatch: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var id: UUID { peripheral.identifier }
}

/// Pure authorization policy for every watch-originated phone action. Keeping
/// the decision separate from CoreBluetooth makes the fail-closed lifecycle
/// cases exhaustively testable without manufacturing a CBPeripheral.
struct WatchActionAuthorization {
    static func allows(token: WatchConnectionToken?,
                       attachedPeripheralID: UUID?,
                       activeWatchID: UUID?,
                       trusted: Bool,
                       sessionReady: Bool,
                       sessionAuthenticated: Bool,
                       connectedKind: WatchKind) -> Bool {
        guard let token,
              token.peripheralID == attachedPeripheralID,
              token.watchID == activeWatchID,
              token.kind == connectedKind,
              trusted,
              sessionReady else { return false }
        switch connectedKind {
        case .fossilQ:
            // Q has no protocol authentication; explicit enrollment is its
            // trust root, reinforced by the exact live connection token.
            return true
        case .hybridHR:
            return sessionAuthenticated
        case .misfitQ, .unknown:
            return false
        }
    }
}

/// A deliberately narrow one-way transfer into a serial dispatch queue. This
/// avoids claiming that every mutable FossilRequest subclass is generally
/// Sendable; WatchManager is the only owner after the transfer.
private struct QueueTransfer<Value>: @unchecked Sendable {
    let value: Value
}

enum ConnectionState: Equatable {
    case bluetoothOff
    case disconnected
    case scanning
    case connecting
    case initializing
    case authenticating
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .bluetoothOff: return String(localized: "Bluetooth is off")
        case .disconnected: return String(localized: "Disconnected")
        case .scanning: return String(localized: "Scanning…")
        case .connecting: return String(localized: "Connecting…")
        case .initializing: return String(localized: "Initializing…")
        case .authenticating: return String(localized: "Authenticating…")
        case .ready: return String(localized: "Connected")
        case .failed(let why): return String(localized: "Failed: \(why)")
        }
    }
}

/// Owns the CoreBluetooth central, the connected watch peripheral and the
/// serialized request queue. All CoreBluetooth work happens on `bleQueue`;
/// published state is updated on the main queue.
// CoreBluetooth and request state are confined to `bleQueue`; published UI
// mirrors are updated on main. The explicit unchecked conformance documents
// that queue-isolation boundary for DispatchQueue's @Sendable closures.
final class WatchManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = WatchManager()

    @Published var connectionState: ConnectionState = .disconnected {
        didSet { connectionObservationDate = Date() }
    }
    @Published private(set) var connectionObservationDate = Date()
    @Published var discovered: [DiscoveredWatch] = []
    /// True while a scan runs. Separate from connectionState: scanning for a
    /// second watch must not disturb the state of the connected one.
    @Published var isScanning = false
    @Published var batteryLevel: Int?
    /// Updated only when a battery value is actually observed.  The setter is
    /// module-internal because the family-specific WatchManager extensions
    /// publish configuration reads from their own source files.
    @Published var batteryObservationDate: Date?
    @Published var firmwareVersion: String?
    @Published var modelNumber: String?
    /// Hardware family of the connected watch, detected from the firmware
    /// string (GB: WatchAdapterFactory). `.unknown` until 2A26 is read.
    @Published var watchKind: WatchKind = .unknown
    /// Scan escape hatch: list every named peripheral instead of only
    /// watch-like ones (the advertised names of older Q watches are unknown).
    /// UI mirror — set via setScanShowsAllDevices.
    @Published private(set) var scanShowsAllDevices = false
    @Published var installedApps: [InstalledApp] = []
    @Published var isAuthenticated = false
    /// BLE bond status as reported by the watch (nil until checked). Bonding
    /// unlocks iOS-native ANCS/AMS on the watch side.
    @Published var isDevicePaired: Bool?
    @Published var log: [LogEntry] = []
    @Published var uploadProgress: Double?
    @Published var liveHeartRate: Int?
    @Published var liveHeartRateActive = false
    /// Step count as reported by the watch's configuration file.
    @Published var watchStepCount: Int?
    /// Name of the last watchface we activated on the active watch
    /// (persisted per watch; the protocol has no way to ask the watch which
    /// face is showing). Loaded in init and on watch switches.
    @Published var activeWatchfaceName: String?
    /// Background of the active watchface, downloaded from the watch itself
    /// and decoded from its .wapp (GB: FossilFileReader.getBackground).
    @Published var activeWatchfaceImage: UIImage?

    let bleQueue = DispatchQueue(label: "hybridge.ble")
    private let logger = Logger(subsystem: "eu.sixpixels.hybridge", category: "ble")
    private var central: CBCentralManager!
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

    /// Dedup index of the last raw button-press frame (requestType 0x08) —
    /// the watch repeats the frame, GB dedups the same way.
    private var lastButtonFrameIndex = -1

    /// True while the user wants a connection maintained (auto-reconnect).
    private var userWantsConnection = false
    /// Peripheral handed back by iOS state restoration matching the active
    /// watch, pending adoption.
    private var restoredPeripheral: CBPeripheral?
    /// Restored peripherals that are NOT the active watch — their pending
    /// connects are cancelled once the central is powered on (iOS would
    /// otherwise keep them alive forever).
    private var strayRestoredPeripherals: [CBPeripheral] = []
    /// bleQueue copy of scanShowsAllDevices (didDiscover runs per advert —
    /// no queue hop for the read).
    private var showAllInScan = false
    /// BLE-queue trust mirrors used for watch-originated phone actions.
    private var sessionReady = false
    private var sessionAuthenticated = false
    private var connectedKind: WatchKind = .unknown

    /// Fires while the app is running to keep a long foreground session
    /// fresh (battery/steps, clock drift, due activity sync). iOS can't run
    /// a free clock in the background, so the authoritative trigger is the
    /// on-connect init; this only covers the watch staying connected for a
    /// long time. See `periodicMaintenance()`.
    private var periodicSyncTimer: Timer?
    /// Throttles `periodicMaintenance` so the foreground trigger doesn't
    /// re-hit the watch on every app switch (read/written on main).
    var lastMaintenanceDate = Date.distantPast

    override init() {
        super.init()
        // Must run before the central is created: state restoration
        // callbacks need the migrated registry.
        AppMigrations.run()
        activeWatchfaceName = UserDefaults.standard.string(forKey: WatchScoped.key(.activeWatchfaceName))
        central = CBCentralManager(delegate: self, queue: bleQueue,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "hybridge.central"])
        DispatchQueue.main.async { self.startPeriodicSync() }
        // Also refresh when the app returns to the foreground — the timer
        // doesn't fire while suspended.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { await self.periodicMaintenance() }
        }
    }

    private func startPeriodicSync() {
        periodicSyncTimer?.invalidate()
        let timer = Timer(timeInterval: Self.maintenanceInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.periodicMaintenance() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        periodicSyncTimer = timer
    }

    // MARK: - Logging

    func addLog(_ text: String) {
        // Payload hex dumps can carry sensitive bytes (auth-handshake frames,
        // body metrics, contact names in notification filters). Log at
        // `.private` so they are redacted in the *persisted* unified log
        // (Console.app, sysdiagnose); the in-app log screen, which the user
        // opens deliberately, still shows the full text from `self.log`.
        logger.info("\(text, privacy: .private)")
        DispatchQueue.main.async {
            self.log.append(LogEntry(text: text))
            if self.log.count > 800 {
                self.log.removeFirst(self.log.count - 800)
            }
        }
    }

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

    var fullLogText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return log.map { "\(formatter.string(from: $0.date)) \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Scanning / connecting

    func startScan() {
        bleQueue.async {
            guard self.central.state == .poweredOn else { return }
            DispatchQueue.main.async {
                self.discovered = []
                self.isScanning = true
                // Only the first-run flow shows the scan as the connection
                // state — while attached to a watch, scanning is a side task.
                if self.connectionState == .disconnected {
                    self.connectionState = .scanning
                }
            }
            // The watch does not advertise its vendor service UUID; scan wide
            // and filter by name.
            self.central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func setScanShowsAllDevices(_ show: Bool) {
        DispatchQueue.main.async { self.scanShowsAllDevices = show }
        bleQueue.async { self.showAllInScan = show }
    }

    func stopScan() {
        bleQueue.async {
            self.central.stopScan()
            DispatchQueue.main.async {
                self.isScanning = false
                if self.connectionState == .scanning {
                    self.connectionState = .disconnected
                }
            }
        }
    }

    func connect(_ peripheral: CBPeripheral) {
        bleQueue.async {
            self.central.stopScan()
            DispatchQueue.main.async { self.isScanning = false }
            // Adding/picking a watch while another one is attached is a
            // switch: drop the old session first.
            if let current = self.peripheral, current.identifier != peripheral.identifier {
                self.teardownSession()
            }
            WatchRegistry.shared.register(id: peripheral.identifier,
                                          name: peripheral.name ?? String(localized: "Fossil watch"))
            self.activateAndReloadScopedState(peripheral.identifier)
            self.userWantsConnection = true
            self.autoPairOnNextInit = true
            self.peripheral = peripheral
            self.establishConnectionToken(for: peripheral)
            peripheral.delegate = self
            DispatchQueue.main.async { self.connectionState = .connecting }
            self.central.connect(peripheral, options: nil)
        }
    }

    /// Makes `id` the active watch: tears the current session down and
    /// connects to it. No-op when it is already the active, attached watch.
    func switchTo(_ id: UUID) {
        bleQueue.async {
            if WatchRegistry.activeWatchIDSync() == id, self.peripheral?.identifier == id { return }
            let name = WatchRegistry.knownWatchesSync().first { $0.id == id }?.name ?? "watch"
            self.addLog("Switching to \(name)")
            self.teardownSession()
            self.activateAndReloadScopedState(id)
            self.connectActiveLocked()
            
        }
    }

    /// Removes a watch from the roster, deleting its auth key and all its
    /// per-watch settings. When it was the active watch, falls back to the
    /// next roster watch (and connects to it).
    func forget(_ id: UUID) {
        bleQueue.async {
            if self.peripheral?.identifier == id {
                self.teardownSession()
            }
            KeychainStore.deleteKey(for: id)
            WatchScoped.purge(watchID: id)
            Task { await ActivityQuarantineStore.shared.clear(watchID: id) }
            WatchRegistry.shared.remove(id)
            if WatchRegistry.activeWatchIDSync() == id {
                if let next = WatchRegistry.knownWatchesSync().first?.id {
                    self.activateAndReloadScopedState(next)
                    self.connectActiveLocked()
                } else {
                    WatchRegistry.shared.setActive(nil)
                    DispatchQueue.main.async { self.activeWatchfaceName = nil }
                }
            }
        }
    }

    /// Persists the new active watch and reloads the per-watch published
    /// state that isn't reset by teardown (on bleQueue).
    private func activateAndReloadScopedState(_ id: UUID) {
        WatchRegistry.shared.setActive(id)
        
        DispatchQueue.main.async {
            WatchSkinStore.shared.reload()
            self.activeWatchfaceName = UserDefaults.standard
                .string(forKey: WatchScoped.key(.activeWatchfaceName, watchID: id))
        }
    }

    /// Tears down the current session (on bleQueue): cancels any in-flight
    /// request, drops the BLE link and clears all per-connection state.
    /// userWantsConnection is cleared first so the old watch's didDisconnect
    /// can't re-arm its auto-reconnect.
    private func teardownSession() {
        invalidateConnectionToken()
        userWantsConnection = false
        failCurrentRequest(FossilError.notConnected)
        if let old = peripheral {
            // Also cancels a still-pending connect.
            central.cancelPeripheralConnection(old)
        }
        peripheral = nil
        characteristics = [:]
        pendingNotifyChars = []
        sessionStarted = false
        initDispatched = false
        pendingPackets = []
        fileVersions = DeviceFileVersions()
        autoPairOnNextInit = false
        lastButtonFrameIndex = -1
        DispatchQueue.main.async {
            self.connectionState = .disconnected
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

    /// Try to reconnect to the active roster watch without scanning.
    func reconnectActive() {
        bleQueue.async { self.connectActiveLocked() }
    }

    /// Connects to the active watch, adopting a state-restored peripheral
    /// when it matches. On bleQueue.
    private func connectActiveLocked() {
        guard central.state == .poweredOn, peripheral == nil,
              let activeID = WatchRegistry.activeWatchIDSync() else { return }
        var candidate: CBPeripheral?
        if let restored = restoredPeripheral, restored.identifier == activeID {
            candidate = restored
        }
        restoredPeripheral = nil
        if candidate == nil {
            candidate = central.retrievePeripherals(withIdentifiers: [activeID]).first
        }
        guard let peripheral = candidate else { return }
        self.userWantsConnection = true
        self.peripheral = peripheral
        establishConnectionToken(for: peripheral)
        peripheral.delegate = self
        if peripheral.state == .connected {
            // Restored while already connected — just resume discovery.
            addLog("Adopting restored connection to \(peripheral.name ?? "watch")")
            DispatchQueue.main.async { self.connectionState = .initializing }
            peripheral.discoverServices(nil)
        } else {
            DispatchQueue.main.async { self.connectionState = .connecting }
            // A pending connect never times out — it fires whenever the
            // watch comes into range, which is what keeps us auto-attached.
            central.connect(peripheral, options: nil)
        }
    }

    func disconnect() {
        bleQueue.async {
            self.userWantsConnection = false
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    var hasKnownWatches: Bool {
        WatchRegistry.hasWatchesSync()
    }

    // MARK: - Request queue

    /// Run a request to completion. Serialized: awaits are chained by the
    /// callers (WatchActions), and a second concurrent call fails fast rather
    /// than interleaving packets on the wire.
    func run(_ request: FossilRequest) async throws {
        // Enforces the architecture's core invariant: every request must be
        // issued inside a `WatchSession.exclusive` block, so no foreign
        // request can land between two requests of someone else's sequence.
        // The task-local is read here in the caller's task context — NOT
        // inside the bleQueue closure below, where it would not propagate.
        //
        // In debug this traps at the offending call site. In release it must
        // NOT silently proceed: an unheld request can interleave into another
        // sequence's handshake and make an encrypted put encrypt under the
        // wrong AES-CTR IV — which on the notification-filter file writes a
        // config the watch reads as empty, silently dropping every
        // notification. Failing the one stray operation is strictly safer than
        // corrupting watch state, so we throw instead.
        guard WatchSession.isHeld else {
            assertionFailure("run(\(request.name)) issued without holding WatchSession.exclusive — see WatchSession.swift")
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
                    self.addLog("  write \(characteristic.uuid.uuidString.prefix(8)): \(data.hexString)")
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

    /// Waits for the active watch to reach `.ready`.
    @discardableResult
    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        await waitUntil(timeout: timeout) { await MainActor.run { self.connectionState == .ready } }
    }

    /// Waits for the family init sequence to finish, so a caller that just
    /// observed `.ready` doesn't race the tail of init's own request queue.
    @discardableResult
    func waitUntilIdle(timeout: TimeInterval) async -> Bool {
        await waitUntil(timeout: timeout) { !Self.initInProgress }
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

extension WatchManager: RequestIO {
    var maxFilePacketPayload: Int {
        guard let peripheral else { return 19 }
        // Always size chunks from the without-response limit: it reflects the
        // real ATT MTU (mtu - 3). The with-response limit can report 512 by
        // assuming ATT long writes, which the watch firmware does not handle.
        let usable = peripheral.maximumWriteValueLength(for: .withoutResponse)
        
        return max(19, min(usable, 509) - 1)
    }

    func write(_ data: Data, to uuid: CBUUID) {
        dispatchPrecondition(condition: .onQueue(bleQueue))
        guard let peripheral, let characteristic = characteristics[uuid] else { return }
        addLog("  write \(uuid.uuidString.prefix(8)): \(data.count <= 32 ? data.hexString : "\(data.count) bytes")")
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
            guard let peripheral, let characteristic = characteristics[FossilUUID.char0004] else { return }
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

// MARK: - CBCentralManagerDelegate

extension WatchManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            DispatchQueue.main.async {
                if self.connectionState == .bluetoothOff {
                    self.connectionState = .disconnected
                }
            }
            // Drop restored pending connects to non-active watches — iOS
            // would keep them alive forever otherwise.
            for stray in strayRestoredPeripherals {
                addLog("Cancelling restored connection to non-active \(stray.name ?? "watch")")
                central.cancelPeripheralConnection(stray)
            }
            strayRestoredPeripherals = []
            if hasKnownWatches || restoredPeripheral != nil {
                connectActiveLocked()
            } else {
                // First launch: go straight to scanning instead of showing
                // an idle scan screen.
                startScan()
            }
        case .poweredOff, .unauthorized, .unsupported:
            DispatchQueue.main.async { self.connectionState = .bluetoothOff }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        // GB's actual discovery rule is the advertised vendor service UUID —
        // shared by every Fossil hybrid generation. The name filter stays as
        // a fallback for adverts that omit the UUID.
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let lowered = name.lowercased()
        let watchLike = serviceUUIDs.contains(FossilUUID.service)
            || lowered.contains("fossil") || lowered.contains("hybrid")
            || lowered.contains("skagen") || lowered.contains("diesel") || lowered.contains("hr")
        guard watchLike || (showAllInScan && !name.isEmpty) else { return }
        let shownName = name.isEmpty ? String(localized: "Fossil watch") : name
        DispatchQueue.main.async {
            if let index = self.discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
                self.discovered[index] = DiscoveredWatch(peripheral: peripheral, name: shownName, rssi: RSSI.intValue)
            } else {
                self.discovered.append(DiscoveredWatch(peripheral: peripheral, name: shownName, rssi: RSSI.intValue))
            }
        }
        // Discovery is intentionally passive. Trust and persistence begin
        // only after the user explicitly selects a scan result.
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        addLog("Connected to \(peripheral.name ?? "watch")")
        WatchRegistry.shared.touchLastConnected(peripheral.identifier)
        sessionStarted = false
        pendingNotifyChars = []
        DispatchQueue.main.async { self.connectionState = .initializing }
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // A cancelled connect for a switched-away watch can land after the
        // new peripheral is assigned — never clear the new one.
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        addLog("Connect failed: \(error?.localizedDescription ?? "unknown")")
        self.peripheral = nil
        invalidateConnectionToken()
        DispatchQueue.main.async {
            self.connectionState = .failed(
                error?.localizedDescription ?? String(localized: "connection failed"))
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // The old watch's disconnect can arrive after a switch has already
        // assigned the new peripheral — ignore it.
        guard peripheral.identifier == self.peripheral?.identifier else {
            addLog("Disconnected stale \(peripheral.name ?? "watch") — ignored")
            return
        }
        addLog("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        failCurrentRequest(FossilError.notConnected)
        let shouldReconnect = userWantsConnection
        invalidateConnectionToken()
        self.peripheral = nil
        self.characteristics = [:]
        self.pendingNotifyChars = []
        self.sessionStarted = false
        self.initDispatched = false
        DispatchQueue.main.async {
            self.connectionState = shouldReconnect ? .connecting : .disconnected
            self.isAuthenticated = false
            self.batteryLevel = nil
            self.batteryObservationDate = nil
            self.installedApps = []
        }
        if shouldReconnect {
            // Re-issue the connect: iOS keeps it pending until the watch is
            // back in range, surviving app suspension via state restoration.
            addLog("Auto-reconnect armed")
            self.peripheral = peripheral
            establishConnectionToken(for: peripheral)
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        } else if !hasKnownWatches {
            // Watch was just forgotten — go straight back to scanning.
            startScan()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        let activeID = WatchRegistry.activeWatchIDSync()
        for restored in peripherals {
            if restored.identifier == activeID {
                addLog("State restoration returned \(restored.name ?? "watch") (\(restored.state == .connected ? "connected" : "not connected"))")
                restoredPeripheral = restored
                restored.delegate = self
                // Adopted in connectActiveLocked() once the central is poweredOn.
            } else {
                strayRestoredPeripherals.append(restored)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension WatchManager: CBPeripheralDelegate {
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

    private static func describeProperties(_ properties: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if properties.contains(.read) { parts.append("read") }
        if properties.contains(.write) { parts.append("write") }
        if properties.contains(.writeWithoutResponse) { parts.append("writeNR") }
        if properties.contains(.notify) { parts.append("notify") }
        if properties.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: "|")
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
            addLog("char \(characteristic.uuid.uuidString.prefix(8)) [\(Self.describeProperties(characteristic.properties))]")
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
        } else {
            addLog("notify \(characteristic.isNotifying ? "on" : "off") for \(characteristic.uuid.uuidString.prefix(8))")
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
            if characteristic.uuid != FossilUUID.char0004 || value.count <= 4 {
                addLog("← \(characteristic.uuid.uuidString.prefix(8)): \(value.count <= 64 ? value.hexString : "\(value.count) bytes: \(value.prefix(24).hexString)…")")
            }
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
        if characteristic.uuid == FossilUUID.char0004 {
            if packetWriteType == .withResponse {
                sendNextPackets()
            }
        } else {
            addLog("  write ok on \(characteristic.uuid.uuidString.prefix(8))")
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
