import XCTest
@testable import Hybridge

final class HomeAssistantTests: XCTestCase {
    func testLegacyConfigurationMigratesToAddedAndEnabled() throws {
        let suiteName = "HomeAssistantTests.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("http://homeassistant.local:8123", forKey: HomeAssistantSettingsStore.addressKey)

        HomeAssistantSettingsStore.migrateIntegrationStateIfNeeded(
            defaults: defaults, tokenExists: { false })

        XCTAssertTrue(defaults.bool(forKey: HomeAssistantSettingsStore.integrationAddedKey))
        XCTAssertTrue(defaults.bool(forKey: HomeAssistantSettingsStore.integrationEnabledKey))
        XCTAssertTrue(defaults.bool(forKey: HomeAssistantSettingsStore.integrationMigrationKey))

        // Once migrated, an explicit disabled state must not be overwritten by
        // credentials that remain stored for later re-enabling.
        defaults.set(false, forKey: HomeAssistantSettingsStore.integrationEnabledKey)
        HomeAssistantSettingsStore.migrateIntegrationStateIfNeeded(
            defaults: defaults, tokenExists: { true })
        XCTAssertFalse(defaults.bool(forKey: HomeAssistantSettingsStore.integrationEnabledKey))
    }

    func testNewUserStartsWithoutHomeAssistantIntegration() throws {
        let suiteName = "HomeAssistantTests.new.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        HomeAssistantSettingsStore.migrateIntegrationStateIfNeeded(
            defaults: defaults, tokenExists: { false })

        XCTAssertFalse(defaults.bool(forKey: HomeAssistantSettingsStore.integrationAddedKey))
        XCTAssertFalse(defaults.bool(forKey: HomeAssistantSettingsStore.integrationEnabledKey))
        XCTAssertTrue(defaults.bool(forKey: HomeAssistantSettingsStore.integrationMigrationKey))
    }

    func testNormalizesHostnameAndKeepsReverseProxyPath() throws {
        XCTAssertEqual(
            try HomeAssistantSettingsStore.normalizedBaseURL(" homeassistant.local:8123/ ").absoluteString,
            "https://homeassistant.local:8123/"
        )
        XCTAssertEqual(
            try HomeAssistantSettingsStore.normalizedBaseURL("https://example.test/ha///").absoluteString,
            "https://example.test/ha"
        )
        XCTAssertThrowsError(try HomeAssistantSettingsStore.normalizedBaseURL("ftp://example.test"))
        XCTAssertThrowsError(try HomeAssistantSettingsStore.normalizedBaseURL(""))
        XCTAssertThrowsError(try HomeAssistantSettingsStore.normalizedBaseURL("http://homeassistant.local:8123")) {
            XCTAssertEqual($0 as? HomeAssistantError, .insecureHTTPNotAllowed)
        }
        XCTAssertEqual(
            try HomeAssistantSettingsStore.normalizedBaseURL(
                "http://homeassistant.local:8123", allowsInsecureHTTP: true).absoluteString,
            "http://homeassistant.local:8123"
        )
        XCTAssertEqual(
            try HomeAssistantSettingsStore.normalizedBaseURL(
                "http://192.168.1.20:8123", allowsInsecureHTTP: true).absoluteString,
            "http://192.168.1.20:8123"
        )
        XCTAssertThrowsError(try HomeAssistantSettingsStore.normalizedBaseURL(
            "http://example.com", allowsInsecureHTTP: true))
        XCTAssertThrowsError(try HomeAssistantSettingsStore.normalizedBaseURL(
            "http://10.attacker.example", allowsInsecureHTTP: true))
        XCTAssertThrowsError(try HomeAssistantSettingsStore.normalizedBaseURL(
            "http://10.0.0.999", allowsInsecureHTTP: true))
        XCTAssertThrowsError(try HomeAssistantSettingsStore.normalizedBaseURL(
            "http://8.8.8.8", allowsInsecureHTTP: true))
    }

    func testConfigurationCapsWatchCarouselAtElevenEntities() throws {
        let selected = (0..<14).map { "sensor.item_\($0)" }
        let configuration = try HomeAssistantSettingsStore.configuration(
            address: "homeassistant.local:8123",
            token: "test-token",
            selectedEntityIDs: selected)

        XCTAssertEqual(HomeAssistantSettingsStore.maximumEntities, 11)
        XCTAssertEqual(configuration.selectedEntityIDs, Array(selected.prefix(11)))
    }

    func testRedirectPolicyRejectsDowngradeAndCrossOrigin() throws {
        let origin = try XCTUnwrap(URL(string: "https://ha.example.test:8443/api/states"))
        XCTAssertTrue(HomeAssistantRedirectDelegate.permitsRedirect(
            from: origin, to: try XCTUnwrap(URL(string: "https://ha.example.test:8443/login"))))
        XCTAssertFalse(HomeAssistantRedirectDelegate.permitsRedirect(
            from: origin, to: try XCTUnwrap(URL(string: "http://ha.example.test:8443/login"))))
        XCTAssertFalse(HomeAssistantRedirectDelegate.permitsRedirect(
            from: origin, to: try XCTUnwrap(URL(string: "https://evil.example:8443/login"))))
        XCTAssertFalse(HomeAssistantRedirectDelegate.permitsRedirect(
            from: origin, to: try XCTUnwrap(URL(string: "https://ha.example.test/login"))))
    }

    func testStateMappingProducesCompactWatchEntity() throws {
        let json = """
        [
          {
            "entity_id":"light.living_room",
            "state":"on",
            "attributes":{"friendly_name":"Living Room","brightness":128}
          },
          {
            "entity_id":"climate.thermostat",
            "state":"heat",
            "attributes":{
              "friendly_name":"Thermostat",
              "current_temperature":19.5,
              "temperature":21,
              "min_temp":16,
              "max_temp":30,
              "target_temp_step":0.5,
              "hvac_modes":["off","heat","cool","auto"]
            }
          },
          {"bad":"entry"}
        ]
        """.data(using: .utf8)!

        let entities = try HomeAssistantEntity.decodeStates(json)
        XCTAssertEqual(entities.count, 2)
        XCTAssertEqual(entities[0].id, "light.living_room")
        XCTAssertEqual(entities[0].brightness, 50)
        XCTAssertEqual(entities[1].type, "climate")
        XCTAssertEqual(entities[1].currentTemperature, 19.5)
        XCTAssertEqual(entities[1].targetTemperature, 21)
        XCTAssertEqual(entities[1].temperatureStep, 0.5)
        XCTAssertEqual(entities[1].hvacModes, ["off", "heat", "cool", "auto"])
    }

    func testWatchControlDecodingAndServiceCalls() throws {
        let brightness = try HomeAssistantControl.decode([
            "entity_id": "light.living_room", "control": "brightness", "value": 110,
        ])
        let brightnessCall = try HomeAssistantAPI.serviceCall(for: brightness)
        XCTAssertEqual(brightnessCall.domain, "light")
        XCTAssertEqual(brightnessCall.service, "turn_on")
        XCTAssertEqual(brightnessCall.body["entity_id"] as? String, "light.living_room")
        XCTAssertEqual(brightnessCall.body["brightness_pct"] as? Double, 100)

        let toggleCall = try HomeAssistantAPI.serviceCall(
            for: .toggle(entityID: "light.living_room"))
        XCTAssertEqual(toggleCall.service, "toggle")

        let modeCall = try HomeAssistantAPI.serviceCall(
            for: .hvacMode(entityID: "climate.thermostat", mode: "cool"))
        XCTAssertEqual(modeCall.domain, "climate")
        XCTAssertEqual(modeCall.service, "set_hvac_mode")
        XCTAssertEqual(modeCall.body["hvac_mode"] as? String, "cool")

        let temperatureCall = try HomeAssistantAPI.serviceCall(
            for: .temperature(entityID: "climate.thermostat", value: 20.5))
        XCTAssertEqual(temperatureCall.service, "set_temperature")
        XCTAssertEqual(temperatureCall.body["temperature"] as? Double, 20.5)

        XCTAssertThrowsError(try HomeAssistantControl.decode([
            "entity_id": "climate.thermostat", "control": "hvac_mode", "value": "auto",
        ]))
        XCTAssertThrowsError(try HomeAssistantAPI.serviceCall(
            for: .toggle(entityID: "switch.not_a_light")))
    }

    func testCorrelatedWatchResponseShape() throws {
        let entity = HomeAssistantEntity(
            id: "light.living_room", name: "Living Room", type: "light", state: "on",
            brightness: 70, currentTemperature: nil, targetTemperature: nil,
            minTemperature: nil, maxTemperature: nil, temperatureStep: nil, hvacModes: nil)
        let data = JsonPayloads.homeAssistantResponse(
            id: 17, token: 170_000_000_001, status: "ok", entities: [entity])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let response = try XCTUnwrap(root["res"] as? [String: Any])
        XCTAssertEqual(response["id"] as? Int, 17)
        let set = try XCTUnwrap(response["set"] as? [String: Any])
        let value = try XCTUnwrap(set["homeAssistantApp._.config.response"] as? [String: Any])
        XCTAssertEqual((value["token"] as? NSNumber)?.int64Value, 170_000_000_001)
        XCTAssertEqual(value["status"] as? String, "ok")
        let entities = try XCTUnwrap(value["entities"] as? [[String: Any]])
        XCTAssertEqual(entities.first?["brightness"] as? Int, 70)

        let errorData = JsonPayloads.homeAssistantResponse(
            id: 18, token: 42, status: "error", message: "Unauthorized")
        let errorRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: errorData) as? [String: Any])
        let errorSet = try XCTUnwrap((errorRoot["res"] as? [String: Any])?["set"] as? [String: Any])
        let errorValue = try XCTUnwrap(errorSet["homeAssistantApp._.config.response"] as? [String: Any])
        XCTAssertEqual(errorValue["message"] as? String, "Unauthorized")
        XCTAssertNil(errorValue["entities"])
    }
}
