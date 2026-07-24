import Foundation
@preconcurrency import CoreBluetooth
import os.log
import UIKit

/// Owns the single CoreBluetooth central and the roster of `WatchConnection`s.
/// The connect / auto-reconnect / state-restoration lifecycle lives here (the
/// central is a process-wide singleton); each `WatchConnection` owns its own
/// peripheral, request queue and `CBPeripheralDelegate`. All CoreBluetooth work
/// runs on the shared `bleQueue`; published state is updated on main.
///
/// Stage 1 keeps exactly one *live* connection at a time (switching disconnects
/// the previous one, non-active restored peripherals are cancelled) — the fleet
/// wiring is in place so Stage 2 can maintain several at once.
final class WatchFleet: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = WatchFleet()

    let bleQueue = DispatchQueue(label: "hybridge.ble")
    private let logger = Logger(subsystem: "eu.sixpixels.hybridge", category: "ble")
    private var central: CBCentralManager!

    /// The connection whose per-watch state the UI facade mirrors.
    @Published private(set) var activeConnection: WatchConnection?
    @Published var discovered: [DiscoveredWatch] = []
    /// True while a scan runs. Separate from a connection's state: scanning for
    /// a second watch must not disturb an attached watch's state.
    @Published var isScanning = false
    /// Scan escape hatch: list every named peripheral instead of only
    /// watch-like ones (older Q watches' advertised names are unknown).
    @Published private(set) var scanShowsAllDevices = false
    @Published var log: [LogEntry] = []
    /// Connection state to show when there is no active watch (first run, or
    /// every watch forgotten): scanning / disconnected / bluetooth-off. The
    /// facade mirrors this whenever `activeConnection` is nil.
    @Published var idleState: ConnectionState = .disconnected

    /// The connection objects, one per roster watch, created lazily and kept
    /// until the watch is forgotten. Guarded by a lock: mutated on `bleQueue`
    /// during the lifecycle, read from main by the facade's token routing.
    private let connectionsLock = NSLock()
    private var connections: [UUID: WatchConnection] = [:]

    /// bleQueue copy of scanShowsAllDevices (didDiscover runs per advert — no
    /// queue hop for the read).
    private var showAllInScan = false
    /// Peripheral handed back by iOS state restoration matching the active
    /// watch, pending adoption.
    private var restoredPeripheral: CBPeripheral?
    /// Restored peripherals that are NOT the active watch — their pending
    /// connects are cancelled once the central is powered on (iOS would
    /// otherwise keep them alive forever).
    private var strayRestoredPeripherals: [CBPeripheral] = []

    /// Fires while the app is running to keep a long foreground session fresh
    /// (battery/steps, clock drift, due activity sync). iOS can't run a free
    /// clock in the background, so the authoritative trigger is the on-connect
    /// init; this only covers a watch staying connected for a long time.
    private var periodicSyncTimer: Timer?

    override init() {
        super.init()
        // Must run before the central is created: state restoration callbacks
        // need the migrated registry.
        AppMigrations.run()
        // Eagerly create the active watch's connection so the facade has state
        // to mirror before the link comes up.
        if let activeID = WatchRegistry.activeWatchIDSync() {
            activeConnection = ensureConnection(for: activeID)
        }
        central = CBCentralManager(delegate: self, queue: bleQueue,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "hybridge.central"])
        DispatchQueue.main.async { self.startPeriodicSync() }
        // Also refresh when the app returns to the foreground — the timer
        // doesn't fire while suspended.
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { await self.runPeriodicMaintenance() }
        }
    }

    private func startPeriodicSync() {
        periodicSyncTimer?.invalidate()
        let timer = Timer(timeInterval: WatchConnection.maintenanceInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.runPeriodicMaintenance() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        periodicSyncTimer = timer
    }

    /// Runs foreground maintenance on the active connection (Stage 1). Stage 2
    /// fans this out across every ready connection.
    func runPeriodicMaintenance() async {
        await activeConnection?.periodicMaintenance()
    }

    // MARK: - Logging

    func addLog(_ text: String, watchID: UUID? = nil) {
        // Payload hex dumps can carry sensitive bytes (auth-handshake frames,
        // body metrics, contact names in notification filters). Log at
        // `.private` so they are redacted in the *persisted* unified log
        // (Console.app, sysdiagnose); the in-app log screen, which the user
        // opens deliberately, still shows the full text from `self.log`.
        logger.info("\(text, privacy: .private)")
        // Attribute the line to a watch by name once there's more than one, so
        // a fleet log is readable.
        let roster = WatchRegistry.knownWatchesSync()
        let display: String
        if roster.count > 1, let watchID,
           let name = roster.first(where: { $0.id == watchID })?.name {
            display = "[\(name)] \(text)"
        } else {
            display = text
        }
        DispatchQueue.main.async {
            self.log.append(LogEntry(text: display, watchID: watchID))
            if self.log.count > 800 {
                self.log.removeFirst(self.log.count - 800)
            }
        }
    }

    var fullLogText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return log.map { "\(formatter.string(from: $0.date)) \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Connection registry

    /// Returns the connection for `id`, creating it if the watch is in the
    /// roster but has no object yet. Thread-safe.
    @discardableResult
    func ensureConnection(for id: UUID) -> WatchConnection {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }
        if let existing = connections[id] { return existing }
        let connection = WatchConnection(fleet: self, watchID: id)
        connections[id] = connection
        return connection
    }

    func connection(for id: UUID?) -> WatchConnection? {
        guard let id else { return nil }
        return connectionsLock.withLock { connections[id] }
    }

    private func allConnections() -> [WatchConnection] {
        connectionsLock.withLock { Array(connections.values) }
    }

    private func removeConnection(_ id: UUID) {
        connectionsLock.withLock { _ = connections.removeValue(forKey: id) }
    }

    var hasKnownWatches: Bool { WatchRegistry.hasWatchesSync() }

    // MARK: - Scanning / connecting

    func startScan() {
        bleQueue.async {
            guard self.central.state == .poweredOn else { return }
            let noActive = self.activeConnection == nil
            DispatchQueue.main.async {
                self.discovered = []
                self.isScanning = true
                // Only the first-run flow (no active connection) shows the scan
                // as the connection state — while attached, scanning is a side
                // task that must not disturb the attached watch's state.
                if noActive, self.idleState == .disconnected { self.idleState = .scanning }
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
            let noActive = self.activeConnection == nil
            DispatchQueue.main.async {
                self.isScanning = false
                if noActive, self.idleState == .scanning { self.idleState = .disconnected }
            }
        }
    }

    func connect(_ peripheral: CBPeripheral) {
        bleQueue.async {
            self.central.stopScan()
            DispatchQueue.main.async { self.isScanning = false }
            let id = peripheral.identifier
            // Adding/picking a watch while another is attached is a switch:
            // drop the old live session first (Stage 1 keeps one live link).
            self.teardownLiveConnections(except: id)
            // A watch already in the roster is a reconnect, not an adoption —
            // only genuinely new watches run the vibrate-and-press gate.
            let isNewWatch = WatchRegistry.shared.watch(id) == nil
            WatchRegistry.shared.register(id: id,
                                          name: peripheral.name ?? String(localized: "Fossil watch"))
            let connection = self.ensureConnection(for: id)
            self.activateAndReloadScopedState(id)
            connection.userWantsConnection = true
            connection.autoPairOnNextInit = true
            connection.adoptingNewWatch = isNewWatch
            connection.attach(peripheral)
            connection.setConnecting()
            self.central.connect(peripheral, options: nil)
        }
    }

    /// Makes `id` the active watch: tears the current live session down and
    /// connects to it. No-op when it is already the active, attached watch.
    func switchTo(_ id: UUID) {
        bleQueue.async {
            if WatchRegistry.activeWatchIDSync() == id,
               self.connection(for: id)?.attachedPeripheral?.identifier == id { return }
            let name = WatchRegistry.knownWatchesSync().first { $0.id == id }?.name ?? "watch"
            self.addLog("Switching to \(name)", watchID: id)
            self.teardownLiveConnections(except: id)
            self.activateAndReloadScopedState(id)
            self.connectActiveLocked()
        }
    }

    /// Cancels an in-flight adoption confirmation on whichever connection is
    /// awaiting one (the phone-side "Cancel" on the buzz-and-press overlay).
    func cancelAdoptionConfirm() {
        bleQueue.async {
            for connection in self.allConnections() { connection.cancelAdoptionConfirmIfPending() }
        }
    }

    /// Removes a watch from the roster, deleting its auth key and all its
    /// per-watch settings. When it was the active watch, falls back to the
    /// next roster watch (and connects to it).
    func forget(_ id: UUID) {
        bleQueue.async {
            if let connection = self.connection(for: id), connection.attachedPeripheral != nil {
                self.teardown(connection)
            }
            KeychainStore.deleteKey(for: id)
            WatchScoped.purge(watchID: id)
            Task { await ActivityQuarantineStore.shared.clear(watchID: id) }
            WatchRegistry.shared.remove(id)
            self.removeConnection(id)
            if WatchRegistry.activeWatchIDSync() == id {
                if let next = WatchRegistry.knownWatchesSync().first?.id {
                    self.activateAndReloadScopedState(next)
                    self.connectActiveLocked()
                } else {
                    WatchRegistry.shared.setActive(nil)
                    DispatchQueue.main.async { self.activeConnection = nil }
                }
            }
        }
    }

    /// Persists the new active watch, points the facade at its connection and
    /// reloads global per-watch UI state (on bleQueue).
    private func activateAndReloadScopedState(_ id: UUID) {
        WatchRegistry.shared.setActive(id)
        let connection = ensureConnection(for: id)
        connection.reloadActiveWatchfaceName()
        DispatchQueue.main.async {
            WatchSkinStore.shared.reload()
            self.activeConnection = connection
        }
    }

    /// Tears down every live connection whose watch id is not `keepID` (Stage
    /// 1 single-live-link behaviour). On bleQueue.
    private func teardownLiveConnections(except keepID: UUID) {
        for connection in allConnections()
        where connection.watchID != keepID && connection.attachedPeripheral != nil {
            teardown(connection)
        }
    }

    /// Drops a connection's BLE link and clears its per-connection state. The
    /// connection resets its own state; the fleet cancels the central link.
    private func teardown(_ connection: WatchConnection) {
        let peripheral = connection.attachedPeripheral
        connection.resetForTeardown()
        if let peripheral {
            // Also cancels a still-pending connect.
            central.cancelPeripheralConnection(peripheral)
        }
    }

    /// Try to reconnect to the active roster watch without scanning.
    func reconnectActive() {
        bleQueue.async { self.connectActiveLocked() }
    }

    /// Connects to the active watch, adopting a state-restored peripheral when
    /// it matches. On bleQueue.
    private func connectActiveLocked() {
        guard central.state == .poweredOn,
              let activeID = WatchRegistry.activeWatchIDSync() else { return }
        let connection = ensureConnection(for: activeID)
        guard connection.attachedPeripheral == nil else { return }
        var candidate: CBPeripheral?
        if let restored = restoredPeripheral, restored.identifier == activeID {
            candidate = restored
        }
        restoredPeripheral = nil
        if candidate == nil {
            candidate = central.retrievePeripherals(withIdentifiers: [activeID]).first
        }
        guard let peripheral = candidate else { return }
        connection.userWantsConnection = true
        connection.attach(peripheral)
        if peripheral.state == .connected {
            // Restored while already connected — just resume discovery.
            addLog("Adopting restored connection to \(peripheral.name ?? "watch")", watchID: activeID)
            connection.setInitializing()
            peripheral.discoverServices(nil)
        } else {
            connection.setConnecting()
            // A pending connect never times out — it fires whenever the watch
            // comes into range, which is what keeps us auto-attached.
            central.connect(peripheral, options: nil)
        }
    }

    func disconnect() {
        bleQueue.async {
            guard let connection = self.connection(for: WatchRegistry.activeWatchIDSync()) else { return }
            connection.userWantsConnection = false
            if let peripheral = connection.attachedPeripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension WatchFleet: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Drop restored pending connects to non-active watches — iOS would
            // keep them alive forever otherwise.
            for stray in strayRestoredPeripherals {
                addLog("Cancelling restored connection to non-active \(stray.name ?? "watch")")
                central.cancelPeripheralConnection(stray)
            }
            strayRestoredPeripherals = []
            if idleState == .bluetoothOff {
                DispatchQueue.main.async { self.idleState = .disconnected }
            }
            if hasKnownWatches || restoredPeripheral != nil {
                connectActiveLocked()
            } else {
                // First launch: go straight to scanning instead of showing an
                // idle scan screen.
                startScan()
            }
        case .poweredOff, .unauthorized, .unsupported:
            DispatchQueue.main.async { self.idleState = .bluetoothOff }
            for connection in allConnections() { connection.setBluetoothOff() }
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
        // shared by every Fossil hybrid generation. The name filter stays as a
        // fallback for adverts that omit the UUID.
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
        // Discovery is intentionally passive. Trust and persistence begin only
        // after the user explicitly selects a scan result.
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let connection = connection(for: peripheral.identifier),
              connection.attachedPeripheral?.identifier == peripheral.identifier else { return }
        addLog("Connected to \(peripheral.name ?? "watch")", watchID: connection.watchID)
        WatchRegistry.shared.touchLastConnected(peripheral.identifier)
        connection.handleConnected()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // A cancelled connect for a switched-away watch can land after the new
        // peripheral is assigned — never clear the new one.
        guard let connection = connection(for: peripheral.identifier),
              connection.attachedPeripheral?.identifier == peripheral.identifier else { return }
        addLog("Connect failed: \(error?.localizedDescription ?? "unknown")", watchID: connection.watchID)
        connection.handleConnectFailed(error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // A disconnect can arrive after a switch has already re-assigned the
        // peripheral — ignore it unless it's the connection's current one.
        guard let connection = connection(for: peripheral.identifier),
              connection.attachedPeripheral?.identifier == peripheral.identifier else {
            addLog("Disconnected stale \(peripheral.name ?? "watch") — ignored")
            return
        }
        addLog("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")", watchID: connection.watchID)
        let shouldReconnect = connection.resetForDisconnect()
        if shouldReconnect {
            // Re-issue the connect: iOS keeps it pending until the watch is
            // back in range, surviving app suspension via state restoration.
            addLog("Auto-reconnect armed", watchID: connection.watchID)
            connection.attach(peripheral)
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
                restored.delegate = ensureConnection(for: restored.identifier)
                // Adopted in connectActiveLocked() once the central is poweredOn.
            } else {
                strayRestoredPeripherals.append(restored)
            }
        }
    }
}
