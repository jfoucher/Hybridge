import Foundation

/// A complication (widget) placed on a custom watchface.
struct WatchfaceWidget: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: String            // e.g. "widgetDate"
    var x: Int                  // center position on the 240×240 face
    var y: Int
    var color: Int              // 0 = white, 1 = black
    var background: String      // "" or widget_bg_* name (without color/.rle)
    /// Draw a progress ring around the complication (step-goal ring).
    /// Optional so designs saved by older versions still decode.
    var goalRing: Bool? = false
    /// Solid disc behind the complication so it stays readable over the
    /// photo (opposite shade of the text color). Optional for old designs.
    var solidFill: Bool? = false
    /// Show the complication's icon above its value. Optional so designs saved
    /// by older versions still decode (defaults to shown).
    var showIcon: Bool? = true
    /// widget2ndTZ only: IANA timezone identifier baked into the face (the
    /// offset is resolved at build time, so DST changes need a rebuild).
    var tzName: String? = nil

    static let size = 76

    var colorName: String { color == 0 ? "white" : "black" }
    var wantsGoalRing: Bool { (goalRing ?? false) && WidgetCatalog.supportsGoalRing(type) }
    var wantsSolidFill: Bool { solidFill ?? false }
    var wantsIcon: Bool { showIcon ?? true }

    /// Code-section entry (and layout node) name. Goal rings ship as separate
    /// precompiled widget variants ("<type>R") with the ring hardcoded — the
    /// stock engine forwards no per-widget flags, and extending the node
    /// config (directly or via "data") crashes the face at init.
    var codeName: String { wantsGoalRing ? "\(type)R" : type }

    /// Name of the background image entry in the .wapp icons section, or nil
    /// when the widget has no background at all. Fill variants use a short
    /// "wbg_" prefix.
    var backgroundRLEName: String? {
        let base: String
        switch (background.isEmpty, wantsSolidFill) {
        case (true, false): return nil
        case (true, true): base = "wbg_solid"
        case (false, false): base = background
        case (false, true):
            base = background.replacingOccurrences(of: "widget_bg_", with: "wbg_") + "_fill"
        }
        return "\(base)\(color).rle"
    }
}

/// Catalog of available complication types the customFace engine can render.
enum WidgetCatalog {
    struct Entry: Identifiable {
        let type: String
        let title: String
        var id: String { type }
        /// Bundled preview PNG name (fossil_hr/<type>_preview.png).
        var previewAsset: String { "\(type)_preview" }
    }

    static let entries: [Entry] = [
        Entry(type: "widgetDate", title: String(localized: "Date")),
        Entry(type: "widgetSteps", title: String(localized: "Steps")),
        Entry(type: "widgetHR", title: String(localized: "Heart rate")),
        Entry(type: "widgetBattery", title: String(localized: "Watch battery")),
        Entry(type: "widgetCalories", title: String(localized: "Calories")),
        Entry(type: "widgetActiveMins", title: String(localized: "Active minutes")),
        Entry(type: "widgetWeather", title: String(localized: "Weather")),
        Entry(type: "widgetChanceOfRain", title: String(localized: "Chance of rain")),
        Entry(type: "widgetUV", title: String(localized: "UV index")),
        Entry(type: "widgetSpO2", title: String(localized: "SpO2")),
        Entry(type: "widget2ndTZ", title: String(localized: "World clock")),
        Entry(type: "widgetCustom", title: String(localized: "Custom text")),
    ]

    private static let weatherTypes: Set<String> = [
        "widgetWeather", "widgetChanceOfRain", "widgetUV",
    ]

    static var availableEntries: [Entry] { entries }

    static func isWeather(_ type: String) -> Bool {
        weatherTypes.contains(type)
    }

    /// Multiple instances of these are allowed per face; each gets an
    /// indexed code entry + layout name (widgetCustom0, widget2ndTZ1, …) and
    /// carries a per-widget "data" config (GB: HybridHRWatchfaceFactory).
    static let indexedTypes: Set<String> = ["widget2ndTZ", "widgetCustom"]

    static let backgrounds: [(name: String, title: String)] = [
        ("", String(localized: "None")),
        ("widget_bg_thin_circle", String(localized: "Thin circle")),
        ("widget_bg_double_circle", String(localized: "Double circle")),
        ("widget_bg_dashed_circle", String(localized: "Dashed circle")),
    ]

    /// Types whose widget code actually draws the goal ring (verified
    /// against the open-source watchface widget sources: only these read
    /// goal_ring / daily_goal).
    static let goalRingTypes: Set<String> = [
        "widgetSteps", "widgetCalories", "widgetActiveMins", "widgetBattery",
    ]

    static func supportsGoalRing(_ type: String) -> Bool {
        goalRingTypes.contains(type)
    }

    /// Whether this complication draws an icon (so the editor offers a
    /// show/hide toggle) — derived from the customFace render spec.
    static func hasIcon(_ type: String) -> Bool {
        let spec = CustomFaceLayout.spec(for: type)
        return spec.iconName != nil || spec.dynIconSrc != nil
    }

    /// Most complications a face may carry. The real ceiling is the firmware's
    /// blank-screen node limit (see CustomFaceLayout.maxNodes); the build also
    /// guards it, but the editor keeps designs comfortably under.
    static let maxComplications = 6

    static func title(for type: String) -> String {
        entries.first { $0.type == type }?.title ?? type
    }
}

/// A free-form text layer. Static layers (valueSource == nil) are rendered
/// on the phone with any iOS font and rotation, then baked into the
/// background image at build time — the watch firmware itself can neither
/// rotate text nor load fonts. Dynamic layers (valueSource != nil) instead
/// bake a per-character glyph atlas (GlyphAtlas) in the chosen font/size and
/// let the watch fill in the live value at runtime (widgetText<i> +
/// text_layout.json) — no rotation, no baked value.
struct WatchfaceTextLayer: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String = String(localized: "Text")
    var x: Int = 120            // center position on the 240×240 face
    var y: Int = 120
    var fontFamily: String = "" // "" = system font
    var bold: Bool = false
    var fontSize: Double = 24   // in face pixels (240×240 canvas)
    var rotation: Double = 0    // degrees, clockwise
    /// Shade as a 2bpp display level: 0 = black … 3 = white.
    var shade: Int = 3
    /// nil = static text (baked on the phone, `text` is shown verbatim).
    /// Otherwise the watch fills in the live value at runtime and `text` is
    /// only used as the editor placeholder when empty.
    var valueSource: WatchfaceValueSource? = nil

    /// The 8-bit gray the display level maps to (same levels the watch shows).
    var grayValue: UInt8 { [0, 85, 170, 255][min(max(shade, 0), 3)] }
}

/// A value the watch itself can read at runtime (via `get_common()` in the
/// widget JS) and render into a dynamic text layer. HR-only.
enum WatchfaceValueSource: String, Codable, CaseIterable, Identifiable {
    case steps, heartRate = "hr", battery = "bat", time, date, weekday = "day"
    case calories = "cal", activeMinutes = "actmin", spo2
    /// `get_common().weatherInfo` — populated only after the watch itself
    /// asks for it (`req_data('{"weatherInfo":{}}')`, mirroring the stock
    /// weatherInfo complication) and only while WeatherProvider's push is
    /// enabled in Settings; shows "--" otherwise. See widget_text.js.
    /// `weatherCondition`/`chanceOfRain`/`uvIndex` all share that same push
    /// (extended with rain/uv fields — PayloadBuilders.weatherInfoResponse)
    /// rather than the stock rain/UV complications' per-node config paths,
    /// which only a node literally named "widgetChanceOfRain"/"widgetUV"
    /// can ever read.
    case weatherTemp = "wtemp", weatherCondition = "wicon", chanceOfRain = "rain", uvIndex = "uv"

    var id: String { rawValue }

    static var availableCases: [Self] { allCases }

    var isWeather: Bool {
        switch self {
        case .weatherTemp, .weatherCondition, .chanceOfRain, .uvIndex: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .steps: return String(localized: "Steps")
        case .heartRate: return String(localized: "Heart rate")
        case .battery: return String(localized: "Battery")
        case .time: return String(localized: "Time")
        case .date: return String(localized: "Date")
        case .weekday: return String(localized: "Day of week")
        case .calories: return String(localized: "Calories")
        case .activeMinutes: return String(localized: "Active minutes")
        case .spo2: return String(localized: "Blood oxygen (SpO₂)")
        case .weatherTemp: return String(localized: "Weather temperature")
        case .weatherCondition: return String(localized: "Weather condition")
        case .chanceOfRain: return String(localized: "Chance of rain")
        case .uvIndex: return String(localized: "UV index")
        }
    }

    /// Shown in the editor/preview in place of a live value — never sent to
    /// the watch, which fills in the real reading at runtime.
    var sampleText: String {
        switch self {
        case .steps: return 12_345.formatted()
        case .heartRate: return "72"
        case .battery: return "100%"
        case .time: return "12:34"
        case .date: return "31"
        case .weekday: return Self.weekdayNames()[3]   // Wednesday
        case .calories: return 1_234.formatted()
        case .activeMinutes: return String(localized: "45m", comment: "Sample active-minutes value")
        case .spo2: return "97%"
        case .weatherTemp: return "72°"
        case .weatherCondition: return String(localized: "CLOUDY", comment: "Sample weather condition shown on a watchface")
        case .chanceOfRain: return "45%"
        case .uvIndex: return "6"
        }
    }

    /// Localized Sunday-first day names, as baked into a weekday layer's
    /// glyph atlas and shipped to the widget via `data.days` (widget JS has
    /// no locale access — `get_common().day` is just a 0–6 index, and the
    /// stock widget_date.js hardcodes English). Uppercased, diacritic-folded
    /// ("mié." → MIE) and stripped to letters/digits ("mer." → MER) so the
    /// glyph asset names stay simple; falls back to English if the locale
    /// yields anything empty. Baked at build time — changing the phone
    /// language means reinstalling the face.
    ///
    /// The default is the user's *system* language, not `Locale.current`:
    /// current follows the app's supported localizations, and this app is
    /// English-only — on a French phone it still says en, which shipped
    /// English day names to a French user.
    static func weekdayNames(locale: Locale? = nil) -> [String] {
        let locale = locale
            ?? Locale.preferredLanguages.first.map(Locale.init(identifier:))
            ?? Locale(identifier: "en_US")
        let english = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        // shortWeekdaySymbols is Sunday-first regardless of the locale's
        // firstWeekday — same order as get_common().day.
        let names = calendar.shortWeekdaySymbols.map { symbol in
            String(symbol.folding(options: .diacriticInsensitive, locale: locale)
                .uppercased(with: locale)
                .filter { $0.isLetter || $0.isNumber }
                .prefix(8))
        }
        guard names.count == 7, names.allSatisfy({ !$0.isEmpty }) else { return english }
        return names
    }

    /// Localized short weather-condition labels, indexed by category:
    /// [0 clear, 1 cloudy, 2 part-cloudy, 3 rain, 4 snow, 5 storm, 6 windy].
    /// Same approach as `weekdayNames`: keyed off the *system* language (the
    /// watch JS has no locale), uppercased/diacritic-folded/letters-only and
    /// ≤8 chars so the glyph names stay simple, with per-entry English
    /// fallback. Shipped as `fields.conds`; the watch maps cond_id → category.
    static func weatherConditionNames(locale: Locale? = nil) -> [String] {
        let locale = locale
            ?? Locale.preferredLanguages.first.map(Locale.init(identifier:))
            ?? Locale(identifier: "en_US")
        let english = ["CLEAR", "CLOUDY", "PTCLOUDY", "RAIN", "SNOW", "STORM", "WINDY"]
        let tables: [String: [String]] = [
            "fr": ["CLAIR", "NUAGEUX", "VARIABLE", "PLUIE", "NEIGE", "ORAGE", "VENT"],
            "de": ["KLAR", "WOLKIG", "WECHSEL", "REGEN", "SCHNEE", "STURM", "WINDIG"],
            "es": ["DESPEJADO", "NUBLADO", "VARIABLE", "LLUVIA", "NIEVE", "TORMENTA", "VIENTO"],
        ]
        let lang = locale.language.languageCode?.identifier ?? "en"
        let source = tables[lang] ?? english
        return source.enumerated().map { index, name in
            let cleaned = String(name.folding(options: .diacriticInsensitive, locale: locale)
                .uppercased(with: locale)
                .filter { $0.isLetter || $0.isNumber }
                .prefix(8))
            return cleaned.isEmpty ? english[index] : cleaned
        }
    }

    /// Every character this source can ever produce — the glyph atlas bakes
    /// exactly this set. `weekday` derives from the localized day names; no
    /// *month* field is exposed by the watch engine anywhere (verified
    /// against fossil-hr-gbapps @ 0734e0e), so `date` stays a bare
    /// zero-padded day number.
    var charset: [Character] {
        let digits = Array("0123456789")
        switch self {
        case .steps: return digits + [","]
        case .heartRate: return digits + ["-"]
        case .battery: return digits + ["%"]
        case .time: return digits + [":"]
        case .date: return digits
        // Union with the English fallback names' letters: if data.days is
        // ever lost or mangled by the firmware's config parser, the widget
        // JS falls back to its built-in English table — every fallback
        // glyph must exist so that failure renders a legible "WED"
        // (a diagnostic signal) instead of missing-icon garbage.
        case .weekday: return Set(Self.weekdayNames().joined() + "SUNMONTUEWEDTHUFRISAT").sorted()
        case .calories: return digits + [","]
        case .activeMinutes: return digits + ["m"]
        // "-" for the "--" off-wrist/no-reading placeholder (same pattern
        // as heartRate).
        case .spo2: return digits + ["%", "-"]
        // "-" for sub-zero readings and the "--" no-data-yet placeholder;
        // "°" for a real reading (GlyphAtlas.assetCode/widget_text.js
        // char_code map it to the short asset code "g").
        case .weatherTemp: return digits + ["-", "°"]
        // Localized condition labels (customFace condition_text) unioned with
        // the English fallback letters (the JS falls back to English if
        // fields.conds is lost), plus "-" for the "--" no-data placeholder.
        case .weatherCondition:
            return Set(Self.weatherConditionNames().joined()
                + "CLEARCLOUDYPTCLOUDYRAINSNOWSTORMWINDY").sorted() + ["-"]
        case .chanceOfRain: return digits + ["%", "-"]
        case .uvIndex: return digits + ["-"]
        }
    }

    /// Longest string this source can ever produce — sizes the "comp"
    /// element's bounding box. The text_layout.json template always ships a
    /// fixed 8 slots regardless (covers every source with room to spare).
    var maxCharacters: Int {
        switch self {
        case .steps: return 6      // "88,888"
        case .heartRate: return 2  // "72" / "--" off-wrist
        case .battery: return 4    // "100%"
        case .time: return 5       // "12:34"
        case .date: return 2       // "31"
        case .weekday: return Self.weekdayNames().map(\.count).max() ?? 3
        case .calories: return 6    // "12,345"
        case .activeMinutes: return 5 // "1440m"
        case .spo2: return 4        // "100%" / "--"
        case .weatherTemp: return 5 // "-104°" — generous margin over any realistic reading
        case .weatherCondition: return 8 // "PTCLOUDY", the longest condition_text label
        case .chanceOfRain: return 4 // "100%"
        case .uvIndex: return 2      // "11"
        }
    }
}

/// A user-designed watchface, persisted locally so it can be re-edited.
struct WatchfaceDesign: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// PNG data of the chosen background photo, or a rendered solid-colour
    /// fill when `backgroundColorHex` is set and no photo was picked (nil =
    /// plain black). This is the single field the build pipeline consumes;
    /// `contrast`/`backgroundColorHex` below are editor state that is baked
    /// into it.
    var backgroundPNG: Data?
    /// Contrast applied to an uploaded background photo (1.0 = untouched).
    /// nil for designs saved before the slider existed.
    var contrast: Double? = nil
    /// Solid background colour used when no photo is picked, as 0x00RRGGBB.
    /// nil = no solid fill chosen (plain black).
    var backgroundColorHex: UInt32? = nil
    var widgets: [WatchfaceWidget] = []
    var textLayers: [WatchfaceTextLayer] = []

    var sanitizedName: String {
        var cleaned = name.replacingOccurrences(of: "[^-A-Za-z0-9]", with: "", options: .regularExpression)
        if cleaned.isEmpty { cleaned = "MyWatchface" }
        if cleaned.hasSuffix("App") { cleaned += "Watchface" }
        return cleaned
    }
}

extension WatchfaceDesign {
    /// Ready-made starting points for the gallery (plain background; the user
    /// adds a photo in the editor). Positions follow the layouts the official
    /// app shipped: top/bottom/left/right anchors on the 240×240 face.
    static let gallery: [WatchfaceDesign] = [
        {
            var design = WatchfaceDesign(name: String(localized: "Classic"))
            design.widgets = [
                WatchfaceWidget(type: "widgetDate", x: 120, y: 58, color: 0,
                                background: "widget_bg_thin_circle"),
                WatchfaceWidget(type: "widgetSteps", x: 120, y: 182, color: 0,
                                background: "widget_bg_thin_circle", goalRing: true),
            ]
            return design
        }(),
        {
            var design = WatchfaceDesign(name: String(localized: "Sport"))
            design.widgets = [
                WatchfaceWidget(type: "widgetDate", x: 120, y: 58, color: 0, background: ""),
                WatchfaceWidget(type: "widgetHR", x: 182, y: 120, color: 0, background: ""),
                WatchfaceWidget(type: "widgetSteps", x: 58, y: 120, color: 0,
                                background: "", goalRing: true),
                WatchfaceWidget(type: "widgetActiveMins", x: 120, y: 182, color: 0,
                                background: "", goalRing: true),
            ]
            return design
        }(),
        {
            var design = WatchfaceDesign(name: String(localized: "Outdoor"))
            design.widgets = [
                WatchfaceWidget(type: "widgetWeather", x: 120, y: 58, color: 0, background: ""),
                WatchfaceWidget(type: "widgetChanceOfRain", x: 58, y: 120, color: 0, background: ""),
                WatchfaceWidget(type: "widgetUV", x: 182, y: 120, color: 0, background: ""),
                WatchfaceWidget(type: "widgetDate", x: 120, y: 182, color: 0, background: ""),
            ]
            return design
        }(),
        {
            var design = WatchfaceDesign(name: String(localized: "Traveler"))
            design.widgets = [
                WatchfaceWidget(type: "widgetDate", x: 120, y: 58, color: 0, background: ""),
                WatchfaceWidget(type: "widget2ndTZ", x: 120, y: 182, color: 0,
                                background: "widget_bg_thin_circle"),
            ]
            return design
        }(),
    ]

    /// Custom decoding so designs saved before text layers existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        backgroundPNG = try container.decodeIfPresent(Data.self, forKey: .backgroundPNG)
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast)
        backgroundColorHex = try container.decodeIfPresent(UInt32.self, forKey: .backgroundColorHex)
        widgets = try container.decode([WatchfaceWidget].self, forKey: .widgets)
        textLayers = try container.decodeIfPresent([WatchfaceTextLayer].self, forKey: .textLayers) ?? []
    }
}

/// Persists designed watchfaces as JSON in Documents.
enum WatchfaceStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watchfaces.json")
    }
    private static var previousValidURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("watchfaces.previous-valid.json")
    }

    static func load() -> [WatchfaceDesign] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let designs = try JSONDecoder().decode([WatchfaceDesign].self, from: data)
            try? data.write(to: previousValidURL, options: [.atomic, .completeFileProtection])
            excludeFromBackup(previousValidURL)
            return designs
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let quarantine = fileURL.deletingLastPathComponent()
                .appendingPathComponent("watchfaces.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: quarantine)
            NSLog("WatchfaceStore: preserved unreadable designs as \(quarantine.lastPathComponent): \(error)")
            guard let previous = try? Data(contentsOf: previousValidURL),
                  let recovered = try? JSONDecoder().decode(
                    [WatchfaceDesign].self, from: previous) else { return [] }
            NSLog("WatchfaceStore: restored the last verified design index")
            return recovered
        }
    }

    static func loadAsync() async -> [WatchfaceDesign] {
        await Task.detached(priority: .utility) { load() }.value
    }

    @discardableResult
    static func save(_ designs: [WatchfaceDesign]) -> Bool {
        do {
            let data = try JSONEncoder().encode(designs)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            let committed = try Data(contentsOf: fileURL)
            guard (try JSONDecoder().decode([WatchfaceDesign].self, from: committed)) == designs else {
                throw CocoaError(.fileWriteUnknown)
            }
            try? committed.write(to: previousValidURL,
                                 options: [.atomic, .completeFileProtection])
            excludeFromBackup(fileURL)
            excludeFromBackup(previousValidURL)
            return true
        } catch {
            NSLog("WatchfaceStore: save failed: \(error)")
            return false
        }
    }

    static func saveAsync(_ designs: [WatchfaceDesign]) async -> Bool {
        await Task.detached(priority: .utility) { save(designs) }.value
    }

    private static func excludeFromBackup(_ candidate: URL) {
        var url = candidate
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
