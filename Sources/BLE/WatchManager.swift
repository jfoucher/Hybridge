import Foundation
import Combine
@preconcurrency import CoreBluetooth
import UIKit

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    /// Which watch produced the line, once the fleet has more than one.
    var watchID: UUID?
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

/// The single `ObservableObject` the UI, widgets and phone-side services talk
/// to. It is a thin facade over `WatchFleet`: it mirrors the **active**
/// connection's published state (so every existing screen sees the active
/// watch unchanged) and forwards actions to the right `WatchConnection`.
///
/// Routing: a token-addressed call (`validatesConnectionToken`,
/// `pushJsonWhenIdle(expectedToken:)`) goes to the connection that owns that
/// token; an action issued inside a `WatchSession.exclusive(for:)` block goes
/// to that block's watch; everything else targets the active watch. This is
/// correct whether one or several watches are connected.
final class WatchManager: ObservableObject, @unchecked Sendable {
    static let shared = WatchManager()

    let fleet = WatchFleet.shared

    // Mirrors of the active connection's per-watch state.
    @Published var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectionObservationDate = Date()
    @Published var batteryLevel: Int?
    @Published var batteryObservationDate: Date?
    @Published var firmwareVersion: String?
    @Published var modelNumber: String?
    @Published var watchKind: WatchKind = .unknown
    @Published var installedApps: [InstalledApp] = []
    @Published var isAuthenticated = false
    @Published var isDevicePaired: Bool?
    @Published var awaitingAdoptionConfirm = false
    @Published var uploadProgress: Double?
    @Published var liveHeartRate: Int?
    @Published var liveHeartRateActive = false
    @Published var watchStepCount: Int?
    @Published var activeWatchfaceName: String?
    @Published var activeWatchfaceImage: UIImage?

    // Mirrors of fleet-level state.
    @Published var discovered: [DiscoveredWatch] = []
    @Published var isScanning = false
    @Published var scanShowsAllDevices = false
    @Published var log: [LogEntry] = []

    /// Cancellables for the currently-mirrored active connection; replaced on
    /// every active-watch change.
    private var activeCancellables: Set<AnyCancellable> = []
    /// Permanent fleet-level bindings.
    private var fleetCancellables: Set<AnyCancellable> = []

    private init() {
        fleet.$discovered.receive(on: RunLoop.main).assign(to: &$discovered)
        fleet.$isScanning.receive(on: RunLoop.main).assign(to: &$isScanning)
        fleet.$scanShowsAllDevices.receive(on: RunLoop.main).assign(to: &$scanShowsAllDevices)
        fleet.$log.receive(on: RunLoop.main).assign(to: &$log)
        fleet.$activeConnection
            .receive(on: RunLoop.main)
            .sink { [weak self] connection in self?.rebindActive(connection) }
            .store(in: &fleetCancellables)
    }

    /// Points every per-watch mirror at `connection`, or resets to defaults
    /// when there is no active watch. Runs on main.
    private func rebindActive(_ connection: WatchConnection?) {
        activeCancellables.removeAll()
        guard let connection else {
            // No active watch: reflect the fleet's idle state (scanning /
            // disconnected / bluetooth-off) for the first-run scan screen.
            fleet.$idleState.receive(on: RunLoop.main)
                .sink { [weak self] value in self?.connectionState = value }
                .store(in: &activeCancellables)
            batteryLevel = nil
            batteryObservationDate = nil
            firmwareVersion = nil
            modelNumber = nil
            watchKind = .unknown
            installedApps = []
            isAuthenticated = false
            isDevicePaired = nil
            awaitingAdoptionConfirm = false
            uploadProgress = nil
            liveHeartRate = nil
            liveHeartRateActive = false
            watchStepCount = nil
            activeWatchfaceName = nil
            activeWatchfaceImage = nil
            return
        }
        func bind<T>(_ publisher: Published<T>.Publisher,
                     _ keyPath: ReferenceWritableKeyPath<WatchManager, T>) {
            publisher.receive(on: RunLoop.main)
                .sink { [weak self] value in self?[keyPath: keyPath] = value }
                .store(in: &activeCancellables)
        }
        bind(connection.$connectionState, \.connectionState)
        bind(connection.$connectionObservationDate, \.connectionObservationDate)
        bind(connection.$batteryLevel, \.batteryLevel)
        bind(connection.$batteryObservationDate, \.batteryObservationDate)
        bind(connection.$firmwareVersion, \.firmwareVersion)
        bind(connection.$modelNumber, \.modelNumber)
        bind(connection.$watchKind, \.watchKind)
        bind(connection.$installedApps, \.installedApps)
        bind(connection.$isAuthenticated, \.isAuthenticated)
        bind(connection.$isDevicePaired, \.isDevicePaired)
        bind(connection.$awaitingAdoptionConfirm, \.awaitingAdoptionConfirm)
        bind(connection.$uploadProgress, \.uploadProgress)
        bind(connection.$liveHeartRate, \.liveHeartRate)
        bind(connection.$liveHeartRateActive, \.liveHeartRateActive)
        bind(connection.$watchStepCount, \.watchStepCount)
        bind(connection.$activeWatchfaceName, \.activeWatchfaceName)
        bind(connection.$activeWatchfaceImage, \.activeWatchfaceImage)
    }

    // MARK: - Constants (re-exported for callers that used WatchManager.X)

    static var autoSyncInterval: TimeInterval { WatchConnection.autoSyncInterval }
    static var maintenanceInterval: TimeInterval { WatchConnection.maintenanceInterval }
    static var maintenanceMinInterval: TimeInterval { WatchConnection.maintenanceMinInterval }

    // MARK: - Connection routing

    /// The connection an action should target: the watch whose session is held
    /// (inside `WatchSession.exclusive(for:)`), else the active watch. Both
    /// lookups are lock-safe and avoid reading the main-affine
    /// `fleet.activeConnection` off the main thread.
    private var target: WatchConnection? {
        fleet.connection(for: WatchSession.connectionToken?.watchID)
            ?? fleet.connection(for: WatchRegistry.activeWatchIDSync())
    }

    private func requireTarget() throws -> WatchConnection {
        guard let target else { throw FossilError.notConnected }
        return target
    }

    var activeConnection: WatchConnection? { fleet.activeConnection }

    // MARK: - Token-addressed helpers

    func connectionTokenSync() -> WatchConnectionToken? {
        target?.connectionTokenSync()
    }

    func validatesConnectionToken(_ token: WatchConnectionToken?) -> Bool {
        guard let token else { return false }
        return fleet.connection(for: token.watchID)?.validatesConnectionToken(token) ?? false
    }

    func acknowledgeMediaAction(_ action: UInt8, token: WatchConnectionToken) {
        fleet.connection(for: token.watchID)?.acknowledgeMediaAction(action, token: token)
    }

    @discardableResult
    func pushJsonWhenIdle(_ json: Data, expectedToken: WatchConnectionToken,
                          attempts: Int = 10) async -> Bool {
        guard let connection = fleet.connection(for: expectedToken.watchID) else { return false }
        return await connection.pushJsonWhenIdle(json, expectedToken: expectedToken, attempts: attempts)
    }

    @discardableResult
    func pushJsonWhenIdle(_ json: Data, attempts: Int = 10) async -> Bool {
        guard let target else { return false }
        return await target.pushJsonWhenIdle(json, attempts: attempts)
    }

    // MARK: - Logging

    func addLog(_ text: String) {
        fleet.addLog(text, watchID: WatchSession.connectionToken?.watchID
                     ?? WatchRegistry.activeWatchIDSync())
    }

    var fullLogText: String { fleet.fullLogText }

    // MARK: - Fleet forwards (scanning, connect lifecycle)

    var hasKnownWatches: Bool { fleet.hasKnownWatches }
    func startScan() { fleet.startScan() }
    func stopScan() { fleet.stopScan() }
    func setScanShowsAllDevices(_ show: Bool) { fleet.setScanShowsAllDevices(show) }
    func connect(_ peripheral: CBPeripheral) { fleet.connect(peripheral) }
    func switchTo(_ id: UUID) { fleet.switchTo(id) }
    func forget(_ id: UUID) { fleet.forget(id) }
    func disconnect() { fleet.disconnect() }
    func reconnectActive() { fleet.reconnectActive() }
    func cancelAdoptionConfirm() { fleet.cancelAdoptionConfirm() }

    // MARK: - Waiting / maintenance forwards

    @discardableResult
    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        await target?.waitUntilReady(timeout: timeout) ?? false
    }

    @discardableResult
    func waitUntilIdle(timeout: TimeInterval) async -> Bool {
        await target?.waitUntilIdle(timeout: timeout) ?? false
    }

    func periodicMaintenance() async { await target?.periodicMaintenance() }
    func syncActivityIfDue(minInterval: TimeInterval = WatchConnection.autoSyncInterval) async {
        await target?.syncActivityIfDue(minInterval: minInterval)
    }

    func setLiveHeartRate(_ enabled: Bool) { target?.setLiveHeartRate(enabled) }

    // MARK: - Action forwards

    func initializeWatch() async { await target?.initializeWatch() }

    func readConfiguration() async throws { try await requireTarget().readConfiguration() }
    func refreshBattery() async throws { try await requireTarget().refreshBattery() }
    func refreshInstalledApps() async throws { try await requireTarget().refreshInstalledApps() }
    func forceFullRefresh() async throws { try await requireTarget().forceFullRefresh() }

    @discardableResult
    func syncActivity(retryQuarantined: Bool = true) async throws -> Int {
        try await requireTarget().syncActivity(retryQuarantined: retryQuarantined)
    }

    func setTime() async throws { try await requireTarget().setTime() }
    func writeConfig(_ items: [ConfigItem]) async throws { try await requireTarget().writeConfig(items) }
    func setAlarms(_ alarms: [WatchAlarm]) async throws { try await requireTarget().setAlarms(alarms) }
    func setButtons(_ selections: [ButtonSelection]) async throws { try await requireTarget().setButtons(selections) }

    func setBodyProfile(gender: ConfigItem.Gender, heightCm: Int, weightKg: Int,
                        birthDate: Date) async throws {
        try await requireTarget().setBodyProfile(gender: gender, heightCm: heightCm,
                                                 weightKg: weightKg, birthDate: birthDate)
    }

    func setWorkoutDetection(_ settings: WorkoutDetectionSettings) async throws {
        try await requireTarget().setWorkoutDetection(settings)
    }

    func setInactivityWarning(enabled: Bool, minutes: Int,
                              from: (Int, Int), until: (Int, Int)) async throws {
        try await requireTarget().setInactivityWarning(enabled: enabled, minutes: minutes,
                                                       from: from, until: until)
    }

    func setNotificationConfigurations() async throws { try await requireTarget().setNotificationConfigurations() }
    func setNotificationFilter(night: Bool) async throws { try await requireTarget().setNotificationFilter(night: night) }
    func playNotification(sender: String, message: String) async throws {
        try await requireTarget().playNotification(sender: sender, message: message)
    }

    func setCustomWidgetText(index: Int = 0, upper: String, lower: String) async throws {
        try await requireTarget().setCustomWidgetText(index: index, upper: upper, lower: lower)
    }

    func startAppOnWatch(_ appName: String) async throws { try await requireTarget().startAppOnWatch(appName) }
    func startWorkoutOnWatch() async throws -> Bool { try await requireTarget().startWorkoutOnWatch() }

    func activateWatchface(named name: String) async throws { try await requireTarget().activateWatchface(named: name) }
    func deleteApp(_ app: InstalledApp) async throws { try await requireTarget().deleteApp(app) }
    func downloadApp(_ app: InstalledApp) async throws -> Data { try await requireTarget().downloadApp(app) }
    func installWatchface(wapp: Data, name: String) async throws { try await requireTarget().installWatchface(wapp: wapp, name: name) }
    func installApp(wapp: Data) async throws { try await requireTarget().installApp(wapp: wapp) }
    func installFirmware(_ firmware: Data) async throws { try await requireTarget().installFirmware(firmware) }
    func installHomeAssistantApp() async throws { try await requireTarget().installHomeAssistantApp() }

    func performDevicePairing() async throws { try await requireTarget().performDevicePairing() }
    func factoryReset() async throws { try await requireTarget().factoryReset() }

    @discardableResult
    func findWatch() async throws -> Bool { try await requireTarget().findWatch() }
    func findActiveWatchAndConfirm() async throws -> Bool? { try await requireTarget().findActiveWatchAndConfirm() }

    func startHandCalibration() async throws { try await requireTarget().startHandCalibration() }
    func moveHands(hour: Int? = nil, minute: Int? = nil, sub: Int? = nil) async throws {
        try await requireTarget().moveHands(hour: hour, minute: minute, sub: sub)
    }
    func endHandCalibration(save: Bool) async throws { try await requireTarget().endHandCalibration(save: save) }

    func downloadForExport(handle: UInt16) async throws -> Data { try await requireTarget().downloadForExport(handle: handle) }
    func deleteFileForDebug(handle: UInt16) async throws { try await requireTarget().deleteFileForDebug(handle: handle) }

    // Q-family forwards
    func vibrateWatch(_ on: Bool) async throws { try await requireTarget().vibrateWatch(on) }
    func setQNotificationFilter() async throws { try await requireTarget().setQNotificationFilter() }
    func setQNotificationFilter(night: Bool) async throws { try await requireTarget().setQNotificationFilter(night: night) }
    func setQButtons() async throws { try await requireTarget().setQButtons() }
    func playQTestNotification(for alert: QNotificationAlert) async throws {
        try await requireTarget().playQTestNotification(for: alert)
    }

    // MARK: - Derived display

    /// The image to show on the dashboard hero for the active watch: the live
    /// face downloaded from the watch when available, otherwise the bundled
    /// face's local artwork matched by the persisted active-face name.
    var activeWatchfacePreviewImage: UIImage? {
        activeWatchfaceImage ?? BundledFaces.matching(name: activeWatchfaceName)?.thumbnail
    }
}
