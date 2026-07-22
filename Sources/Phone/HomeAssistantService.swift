import Foundation
import Security
import Darwin

extension Notification.Name {
    /// Posted whenever the optional Home Assistant integration is added,
    /// enabled/disabled, or removed so settings screens can refresh.
    static let homeAssistantIntegrationChanged = Notification.Name(
        "homeAssistantIntegrationChanged")
}

enum HomeAssistantLog {
    /// DEBUG-only diagnostics visible in Xcode's console. Never pass a bearer
    /// token or Authorization header here. Watch request/response JSON may
    /// contain entity IDs and states, so it must remain excluded from release.
    static func print(_ message: @autoclosure () -> String) {
#if DEBUG
        Swift.print("[HomeAssistant] \(message())")
#endif
    }
}

/// The small entity representation shared with homeAssistantApp.wapp.
/// Home Assistant's REST state objects contain many more fields; keeping only
/// these makes the BLE JSON response predictable and small.
struct HomeAssistantEntity: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: String
    let state: String
    let brightness: Int?
    let currentTemperature: Double?
    let targetTemperature: Double?
    let minTemperature: Double?
    let maxTemperature: Double?
    let temperatureStep: Double?
    let hvacModes: [String]?

    var watchDictionary: [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "name": name,
            "type": type,
            "state": state,
        ]
        if let brightness { value["brightness"] = brightness }
        if let currentTemperature { value["current_temperature"] = currentTemperature }
        if let targetTemperature { value["target_temperature"] = targetTemperature }
        if let minTemperature { value["min_temperature"] = minTemperature }
        if let maxTemperature { value["max_temperature"] = maxTemperature }
        if let temperatureStep { value["temperature_step"] = temperatureStep }
        if let hvacModes { value["hvac_modes"] = hvacModes }
        return value
    }

    static func decodeStates(_ data: Data) throws -> [HomeAssistantEntity] {
        guard let states = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HomeAssistantError.invalidResponse
        }
        guard states.count <= 10_000 else { throw HomeAssistantError.invalidResponse }
        return states.compactMap(fromState)
    }

    static func decodeState(_ data: Data) throws -> HomeAssistantEntity {
        guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entity = fromState(state) else {
            throw HomeAssistantError.invalidResponse
        }
        return entity
    }

    private static func fromState(_ object: [String: Any]) -> HomeAssistantEntity? {
        guard let id = object["entity_id"] as? String, id.utf8.count <= 255,
              let state = object["state"] as? String, state.utf8.count <= 1024 else { return nil }
        let attributes = object["attributes"] as? [String: Any] ?? [:]
        let domain = id.split(separator: ".", maxSplits: 1).first.map(String.init) ?? "entity"
        let fallbackName = id.split(separator: ".", maxSplits: 1).last
            .map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? id
        let name = String((attributes["friendly_name"] as? String ?? fallbackName).prefix(128))

        let rawBrightness = number(attributes["brightness"])
        let brightness = rawBrightness.map {
            min(100, max(0, Int(($0 / 255.0 * 100.0).rounded())))
        }
        let modes = attributes["hvac_modes"] as? [String]
        return HomeAssistantEntity(
            id: id,
            name: name,
            type: domain,
            state: state,
            brightness: brightness,
            currentTemperature: number(attributes["current_temperature"]),
            targetTemperature: number(attributes["temperature"]),
            minTemperature: number(attributes["min_temp"]),
            maxTemperature: number(attributes["max_temp"]),
            temperatureStep: number(attributes["target_temp_step"]),
            hvacModes: modes
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, number.doubleValue.isFinite {
            return number.doubleValue
        }
        if let string = value as? String, let number = Double(string), number.isFinite {
            return number
        }
        return nil
    }
}

enum HomeAssistantError: LocalizedError, Equatable {
    case integrationDisabled
    case invalidAddress
    case insecureHTTPNotAllowed
    case missingToken
    case credentialSaveFailed
    case noSelectedEntities
    case selectedEntitiesUnavailable
    case unauthorized
    case serverStatus(Int)
    case invalidResponse
    case entityNotSelected
    case unsupportedControl

    var errorDescription: String? {
        switch self {
        case .integrationDisabled: return String(localized: "Home Assistant is not enabled")
        case .invalidAddress: return String(localized: "Enter a valid Home Assistant URL")
        case .insecureHTTPNotAllowed: return String(localized: "HTTP exposes your Home Assistant token. Use HTTPS or explicitly allow insecure local HTTP.")
        case .missingToken: return String(localized: "Enter a long-lived access token")
        case .credentialSaveFailed: return String(localized: "Could not save the Home Assistant token")
        case .noSelectedEntities: return String(localized: "No Home Assistant entities selected")
        case .selectedEntitiesUnavailable: return String(localized: "Selected entities were not found")
        case .unauthorized: return String(localized: "Home Assistant rejected the access token")
        case .serverStatus(let status): return String(localized: "Home Assistant returned HTTP \(status)")
        case .invalidResponse: return String(localized: "Home Assistant returned an invalid response")
        case .entityNotSelected: return String(localized: "That entity is not enabled for the watch")
        case .unsupportedControl: return String(localized: "Unsupported Home Assistant control")
        }
    }
}

struct HomeAssistantConfiguration: Equatable, Sendable {
    let baseURL: URL
    let token: String
    let selectedEntityIDs: [String]
}

/// Global Home Assistant settings. They are deliberately not watch-scoped:
/// the phone talks to one home and any paired Hybrid HR can use the same
/// selected carousel. The bearer token itself is stored in Keychain below.
enum HomeAssistantSettingsStore {
    static let addressKey = "homeAssistantAddress"
    static let selectedEntitiesKey = "homeAssistantSelectedEntities"
    static let integrationAddedKey = "homeAssistantIntegrationAdded"
    static let integrationEnabledKey = "homeAssistantIntegrationEnabled"
    static let integrationMigrationKey = "homeAssistantIntegrationStateMigrated"
    static let allowsInsecureHTTPKey = "homeAssistantAllowsInsecureHTTP"
    /// The watch reserves the 3-o'clock launcher slot for Home, leaving eleven
    /// perimeter slots for user-selected entities.
    static let maximumEntities = 11

    /// Whether Home Assistant has been added to the user's integrations list.
    /// This is separate from `isEnabled` so it can be switched off without
    /// discarding credentials or entity choices.
    static var isAdded: Bool {
        migrateIntegrationStateIfNeeded()
        return UserDefaults.standard.bool(forKey: integrationAddedKey)
    }

    static var isEnabled: Bool {
        migrateIntegrationStateIfNeeded()
        return UserDefaults.standard.bool(forKey: integrationEnabledKey)
    }

    static func addIntegration() {
        migrateIntegrationStateIfNeeded()
        UserDefaults.standard.set(true, forKey: integrationAddedKey)
        UserDefaults.standard.set(true, forKey: integrationEnabledKey)
        notifyIntegrationChanged()
    }

    static func setEnabled(_ enabled: Bool) {
        migrateIntegrationStateIfNeeded()
        // Enabling from any future entry point also makes the integration
        // visible in the configured list.
        if enabled {
            UserDefaults.standard.set(true, forKey: integrationAddedKey)
        }
        UserDefaults.standard.set(enabled, forKey: integrationEnabledKey)
        notifyIntegrationChanged()
    }

    /// One-time migration for builds that predate the integrations screen.
    /// Existing Home Assistant users retain the feature as added and enabled;
    /// everybody else starts with it absent.
    static func migrateIntegrationStateIfNeeded(
        defaults: UserDefaults = .standard,
        tokenExists: () -> Bool = { HomeAssistantCredentialStore.loadToken() != nil }
    ) {
        guard !defaults.bool(forKey: integrationMigrationKey) else { return }
        let hasLegacyConfiguration = !(defaults.string(forKey: addressKey) ?? "").isEmpty
            || !(defaults.stringArray(forKey: selectedEntitiesKey) ?? []).isEmpty
            || tokenExists()
        defaults.set(hasLegacyConfiguration, forKey: integrationAddedKey)
        defaults.set(hasLegacyConfiguration, forKey: integrationEnabledKey)
        defaults.set(true, forKey: integrationMigrationKey)
    }

    static var address: String {
        get { UserDefaults.standard.string(forKey: addressKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: addressKey) }
    }

    static var allowsInsecureHTTP: Bool {
        get { UserDefaults.standard.bool(forKey: allowsInsecureHTTPKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowsInsecureHTTPKey) }
    }

    static var selectedEntityIDs: [String] {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: selectedEntitiesKey) ?? []
            let limited = Array(stored.prefix(maximumEntities))
            // Repair selections saved by builds that previously allowed 12.
            if limited.count != stored.count {
                UserDefaults.standard.set(limited, forKey: selectedEntitiesKey)
            }
            return limited
        }
        set { UserDefaults.standard.set(Array(newValue.prefix(maximumEntities)), forKey: selectedEntitiesKey) }
    }

    static func configuration() throws -> HomeAssistantConfiguration {
        let storedToken = HomeAssistantCredentialStore.loadToken() ?? ""
        HomeAssistantLog.print("Loading stored configuration: address=\(!address.isEmpty), token=\(!storedToken.isEmpty), selected=\(selectedEntityIDs.count)")
        return try configuration(address: address, token: storedToken,
                                 selectedEntityIDs: selectedEntityIDs,
                                 allowsInsecureHTTP: allowsInsecureHTTP)
    }

    static func configuration(address: String, token: String,
                              selectedEntityIDs: [String],
                              allowsInsecureHTTP: Bool = false) throws -> HomeAssistantConfiguration {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw HomeAssistantError.missingToken }
        return HomeAssistantConfiguration(
            baseURL: try normalizedBaseURL(address, allowsInsecureHTTP: allowsInsecureHTTP),
            token: trimmedToken,
            selectedEntityIDs: Array(selectedEntityIDs.prefix(maximumEntities))
        )
    }

    static func normalizedBaseURL(_ address: String,
                                  allowsInsecureHTTP: Bool = false) throws -> URL {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw HomeAssistantError.invalidAddress }
        if !value.contains("://") { value = "https://" + value }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil, components.password == nil else {
            throw HomeAssistantError.invalidAddress
        }
        guard scheme == "https"
                || (allowsInsecureHTTP && isPrivateAddressLiteral(components.host ?? "")) else {
            throw HomeAssistantError.insecureHTTPNotAllowed
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else { throw HomeAssistantError.invalidAddress }
        return url
    }

    /// Insecure HTTP is deliberately limited to numeric private literals.
    /// Accepting `.local`, dotless, or private-looking prefixes before DNS
    /// resolution permits DNS rebinding and names such as 10.attacker.test.
    static func isPrivateAddressLiteral(_ host: String) -> Bool {
        let value = host.lowercased()
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8(String($0)) }
        if parts.count == 4,
           parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
           octets.count == 4 {
            return octets[0] == 10
                || octets[0] == 127
                || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }

        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let linkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
        let uniqueLocal = (bytes[0] & 0xFE) == 0xFC
        return loopback || linkLocal || uniqueLocal
    }

    static func removeIntegration() {
        HomeAssistantLog.print("Removing integration, stored address, selection, and token")
        UserDefaults.standard.removeObject(forKey: addressKey)
        UserDefaults.standard.removeObject(forKey: selectedEntitiesKey)
        UserDefaults.standard.removeObject(forKey: allowsInsecureHTTPKey)
        UserDefaults.standard.set(false, forKey: integrationAddedKey)
        UserDefaults.standard.set(false, forKey: integrationEnabledKey)
        UserDefaults.standard.set(true, forKey: integrationMigrationKey)
        HomeAssistantCredentialStore.deleteToken()
        notifyIntegrationChanged()
    }

    private static func notifyIntegrationChanged() {
        NotificationCenter.default.post(name: .homeAssistantIntegrationChanged, object: nil)
    }
}

/// Long-lived Home Assistant bearer token. It must never be mirrored into
/// UserDefaults, logs, or watch JSON.
enum HomeAssistantCredentialStore {
    private static let service = "eu.sixpixels.hybridge.homeassistant"
    private static let account = "long-lived-access-token.v2.device-only"
    private static let legacyAccount = "long-lived-access-token"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static var query: [String: Any] { query(account: account) }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !data.isEmpty else {
            HomeAssistantLog.print("Keychain save rejected an empty token")
            return false
        }

        // Update in place first so a transient add failure cannot destroy a
        // previously working token. Add only when no item exists yet.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            HomeAssistantLog.print("Keychain token updated (length=\(data.count))")
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            HomeAssistantLog.print("Keychain token update failed (OSStatus=\(updateStatus))")
            return false
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        HomeAssistantLog.print(addStatus == errSecSuccess
            ? "Keychain token created (length=\(data.count))"
            : "Keychain token create failed (OSStatus=\(addStatus))")
        return addStatus == errSecSuccess
    }

    static func loadToken() -> String? {
        if let current = load(account: account) { return current }
        guard let legacy = load(account: legacyAccount) else { return nil }
        // Add + read-back + compare before deleting the working legacy item.
        guard saveToken(legacy), load(account: account) == legacy else {
            HomeAssistantLog.print("Keychain token migration deferred; legacy item retained")
            return legacy
        }
        SecItemDelete(query(account: legacyAccount) as CFDictionary)
        return legacy
    }

    private static func load(account: String) -> String? {
        var item = query(account: account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            HomeAssistantLog.print(status == errSecItemNotFound
                ? "Keychain token not found"
                : "Keychain token load failed (OSStatus=\(status))")
            return nil
        }
        HomeAssistantLog.print("Keychain token loaded (length=\(data.count))")
        return token
    }

    static func deleteToken() {
        let statuses = [account, legacyAccount].map {
            SecItemDelete(query(account: $0) as CFDictionary)
        }
        let succeeded = statuses.allSatisfy { $0 == errSecSuccess || $0 == errSecItemNotFound }
        HomeAssistantLog.print(succeeded
            ? "Keychain token versions deleted"
            : "Keychain token delete failed")
    }
}

enum HomeAssistantControl: Equatable, Sendable {
    case toggle(entityID: String)
    case brightness(entityID: String, percent: Double)
    case hvacMode(entityID: String, mode: String)
    case temperature(entityID: String, value: Double)

    var entityID: String {
        switch self {
        case .toggle(let id), .brightness(let id, _), .hvacMode(let id, _),
                .temperature(let id, _): return id
        }
    }

    static func decode(_ request: [String: Any]) throws -> HomeAssistantControl {
        guard let entityID = request["entity_id"] as? String,
              let control = request["control"] as? String else {
            throw HomeAssistantError.unsupportedControl
        }
        switch control {
        case "toggle":
            return .toggle(entityID: entityID)
        case "brightness":
            guard let value = request["value"] as? NSNumber else {
                throw HomeAssistantError.unsupportedControl
            }
            return .brightness(entityID: entityID, percent: value.doubleValue)
        case "hvac_mode":
            guard let mode = request["value"] as? String,
                  ["off", "heat", "cool"].contains(mode) else {
                throw HomeAssistantError.unsupportedControl
            }
            return .hvacMode(entityID: entityID, mode: mode)
        case "temperature":
            guard let value = request["value"] as? NSNumber,
                  value.doubleValue.isFinite else {
                throw HomeAssistantError.unsupportedControl
            }
            return .temperature(entityID: entityID, value: value.doubleValue)
        default:
            throw HomeAssistantError.unsupportedControl
        }
    }
}

/// REST client for Home Assistant's /api/states and /api/services endpoints.
/// URLSession is thread-safe; @unchecked is only needed because Foundation's
/// declaration was not Sendable on the oldest iOS 17 SDK supported here.
final class HomeAssistantRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func permitsRedirect(from original: URL, to destination: URL) -> Bool {
        original.scheme?.lowercased() == "https"
            && destination.scheme?.lowercased() == "https"
            && original.host?.lowercased() == destination.host?.lowercased()
            && original.port == destination.port
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url,
              let destination = request.url,
              Self.permitsRedirect(from: original, to: destination) else {
            completionHandler(nil)
            return
        }
        // URLSession may copy Authorization to a redirected request. Rebuild
        // it only for the exact same HTTPS origin.
        completionHandler(request)
    }
}

final class HomeAssistantAPI: @unchecked Sendable {
    static let shared = HomeAssistantAPI()
    static let maximumResponseBytes = 512 * 1024
    private let session: URLSession
    private let redirectDelegate: HomeAssistantRedirectDelegate?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            redirectDelegate = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 10
            let delegate = HomeAssistantRedirectDelegate()
            redirectDelegate = delegate
            self.session = URLSession(configuration: configuration,
                                      delegate: delegate, delegateQueue: nil)
        }
    }

    func fetchAll(configuration: HomeAssistantConfiguration) async throws -> [HomeAssistantEntity] {
        let url = configuration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("states")
        let data = try await perform(url: url, token: configuration.token)
        let entities = try HomeAssistantEntity.decodeStates(data)
        HomeAssistantLog.print("Decoded \(entities.count) states")
        return entities
    }

    func fetchConfigured(configuration: HomeAssistantConfiguration) async throws -> [HomeAssistantEntity] {
        guard !configuration.selectedEntityIDs.isEmpty else {
            throw HomeAssistantError.noSelectedEntities
        }
        var selected: [HomeAssistantEntity] = []
        selected.reserveCapacity(configuration.selectedEntityIDs.count)
        for entityID in configuration.selectedEntityIDs {
            try Task.checkCancellation()
            let url = configuration.baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("states")
                .appendingPathComponent(entityID)
            do {
                selected.append(try HomeAssistantEntity.decodeState(
                    await perform(url: url, token: configuration.token)))
            } catch HomeAssistantError.serverStatus(404) {
                continue
            }
        }
        guard !selected.isEmpty else { throw HomeAssistantError.selectedEntitiesUnavailable }
        return selected
    }

    func control(_ control: HomeAssistantControl,
                 configuration: HomeAssistantConfiguration) async throws -> [HomeAssistantEntity] {
        guard configuration.selectedEntityIDs.contains(control.entityID) else {
            throw HomeAssistantError.entityNotSelected
        }
        let call = try Self.serviceCall(for: control)
        let url = configuration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("services")
            .appendingPathComponent(call.domain)
            .appendingPathComponent(call.service)
        _ = try await perform(url: url, method: "POST", token: configuration.token,
                              body: call.body)
        // Return a fresh, complete selected list. The service response only
        // guarantees changed states and may omit the controlled entity.
        return try await fetchConfigured(configuration: configuration)
    }

    static func serviceCall(for control: HomeAssistantControl)
        throws -> (domain: String, service: String, body: [String: Any]) {
        switch control {
        case .toggle(let entityID):
            guard entityID.hasPrefix("light.") else { throw HomeAssistantError.unsupportedControl }
            return ("light", "toggle", ["entity_id": entityID])
        case .brightness(let entityID, let percent):
            guard entityID.hasPrefix("light."), percent.isFinite else {
                throw HomeAssistantError.unsupportedControl
            }
            return ("light", "turn_on", [
                "entity_id": entityID,
                "brightness_pct": min(100, max(0, percent.rounded())),
            ])
        case .hvacMode(let entityID, let mode):
            guard entityID.hasPrefix("climate."), ["off", "heat", "cool"].contains(mode) else {
                throw HomeAssistantError.unsupportedControl
            }
            return ("climate", "set_hvac_mode", ["entity_id": entityID, "hvac_mode": mode])
        case .temperature(let entityID, let value):
            guard entityID.hasPrefix("climate."), value.isFinite else {
                throw HomeAssistantError.unsupportedControl
            }
            return ("climate", "set_temperature", ["entity_id": entityID, "temperature": value])
        }
    }

    private func perform(url: URL, method: String = "GET", token: String,
                         body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        HomeAssistantLog.print("HTTP \(method) \(url.absoluteString) started (tokenLength=\(token.utf8.count))")
        let data: Data
        let response: URLResponse
        do {
            let (bytes, initialResponse) = try await session.bytes(for: request)
            response = initialResponse
            var bounded = Data()
            if initialResponse.expectedContentLength > Self.maximumResponseBytes {
                throw HomeAssistantError.invalidResponse
            }
            bounded.reserveCapacity(max(0, min(Int(initialResponse.expectedContentLength),
                                               Self.maximumResponseBytes)))
            for try await byte in bytes {
                guard bounded.count < Self.maximumResponseBytes else {
                    throw HomeAssistantError.invalidResponse
                }
                bounded.append(byte)
            }
            data = bounded
        } catch {
            HomeAssistantLog.print("HTTP \(method) failed before a response: \(error.localizedDescription)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            HomeAssistantLog.print("HTTP \(method) returned a non-HTTP response")
            throw HomeAssistantError.invalidResponse
        }
        HomeAssistantLog.print("HTTP \(method) completed: status=\(http.statusCode), bytes=\(data.count)")
        if http.statusCode == 401 { throw HomeAssistantError.unauthorized }
        guard 200..<300 ~= http.statusCode else {
            throw HomeAssistantError.serverStatus(http.statusCode)
        }
        guard let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.contains("application/json") || contentType.contains("+json") else {
            throw HomeAssistantError.invalidResponse
        }
        return data
    }
}

/// Turns a req_data payload from homeAssistantApp.wapp into a correlated
/// config response. Network work stays outside the BLE queue; the final JSON
/// push goes through WatchManager's serialized request/session path.
enum HomeAssistantBridge {
    static func handle(_ request: [String: Any], requestID: Int,
                       connection: WatchConnectionToken,
                       api: HomeAssistantAPI = .shared) async {
        guard let tokenNumber = request["token"] as? NSNumber else {
            HomeAssistantLog.print("Ignoring malformed watch request id=\(requestID): token missing")
            return
        }
        let token = tokenNumber.int64Value
        let action = request["action"] as? String ?? "missing"
#if DEBUG
        let requestJSON = (try? JSONSerialization.data(withJSONObject: request))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "<unencodable>"
        HomeAssistantLog.print(
            "Watch request received: transportID=\(requestID), action=\(action), " +
            "watchToken=\(token), json=\(requestJSON)")
#endif
        do {
            guard HomeAssistantSettingsStore.isEnabled else {
                throw HomeAssistantError.integrationDisabled
            }
            let configuration = try HomeAssistantSettingsStore.configuration()
            let entities: [HomeAssistantEntity]
            switch request["action"] as? String {
            case "entities":
                entities = try await api.fetchConfigured(configuration: configuration)
            case "control":
                entities = try await api.control(try HomeAssistantControl.decode(request),
                                                 configuration: configuration)
            default:
                throw HomeAssistantError.unsupportedControl
            }
            let response = JsonPayloads.homeAssistantResponse(
                id: requestID, token: token, status: "ok", entities: entities)
            logResponse(response, requestID: requestID, status: "ok",
                        entityCount: entities.count)
            let sent = await WatchManager.shared.pushJsonWhenIdle(
                response, expectedToken: connection)
            HomeAssistantLog.print(sent
                ? "BLE watch response sent: transportID=\(requestID), status=ok"
                : "BLE watch response FAILED after retries: transportID=\(requestID), status=ok")
        } catch {
            let message = String(error.localizedDescription.prefix(80))
            HomeAssistantLog.print("Watch request failed: transportID=\(requestID), action=\(action), error=\(message)")
#if DEBUG
            WatchManager.shared.addLog("Home Assistant request failed: \(message)")
#endif
            let response = JsonPayloads.homeAssistantResponse(
                id: requestID, token: token, status: "error", message: message)
            logResponse(response, requestID: requestID, status: "error", entityCount: 0)
            let sent = await WatchManager.shared.pushJsonWhenIdle(
                response, expectedToken: connection)
            HomeAssistantLog.print(sent
                ? "BLE watch response sent: transportID=\(requestID), status=error"
                : "BLE watch response FAILED after retries: transportID=\(requestID), status=error")
        }
    }

    private static func logResponse(_ response: Data, requestID: Int,
                                    status: String, entityCount: Int) {
#if DEBUG
        let json = String(data: response, encoding: .utf8) ?? "<non-UTF8>"
        HomeAssistantLog.print(
            "Watch response prepared: transportID=\(requestID), status=\(status), " +
            "entities=\(entityCount), bytes=\(response.count), json=\(json)")
#endif
    }
}
