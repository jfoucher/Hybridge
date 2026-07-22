import Foundation

/// Generates the on-watch layout tree + value field-map that the author-original
/// `customFace` engine (moon-watch/custom_face/app.js) renders, from a
/// `WatchfaceDesign`. The phone
/// bakes (1) a layout node tree whose text / image_name / arc-angle fields carry
/// "#placeholder" refs at the dragged positions, and (2) a field map naming each
/// placeholder's get_common() source. `customFace` computes every value and
/// fills the placeholders through one layout_parser_json draw.
///
/// Node shapes mirror this repo's own on-hardware-proven bundled faces
/// (moon-watch faces/sector, faces/meteo): a root 240×240 container, an
/// absolute-placed background image, then per complication an optional
/// background image + goal-ring arc + icon image + a centered text container.
///
/// NOTE: exact pixel placements and font sizes below are a first pass tuned to
/// look right on paper; they need on-watch verification (BLE + rendering exist
/// only on real hardware, and a bad upload reboots the watch).
enum CustomFaceLayout {

    static let layoutName = "cf_layout"
    static let canvas = 240
    static let widgetBox = WatchfaceWidget.size   // 76

    // Tunable geometry (face pixels).
    static let iconBox = 32          // must match the built icon .rle dimensions (Makefile ICON_W/H)
    private static let ringRadius = 36
    private static let ringBorder = 4
    private static let valuePpem = 20
    private static let valueAscent = 13
    private static let valueDescent = 3

    /// Above this node count the firmware renders a blank screen (moon-watch
    /// CLAUDE.md: 32 nodes blanks; official faces run 17–21). Kept conservative.
    static let maxNodes = 30

    /// What a widget type renders: a value source, an optional icon (static
    /// asset name, or a dynamic-icon source resolved on-watch), and whether it
    /// can carry a goal ring.
    struct Spec {
        var valueSrc: String?
        var iconName: String?      // static icon asset
        var dynIconSrc: String?    // "wcond" | "bstate" → on-watch image name
        var ringSrc: String?       // when the widget's goal ring is on
    }

    static func spec(for type: String) -> Spec {
        switch type {
        case "widgetDate":         return Spec()   // special-cased: day number above weekday, centered
        case "widgetSteps":        return Spec(valueSrc: "steps", iconName: "icSteps", ringSrc: "steps")
        case "widgetHR":           return Spec(valueSrc: "hr", iconName: "icHeart")
        case "widgetBattery":      return Spec(valueSrc: "bat", dynIconSrc: "bstate", ringSrc: "bat")
        case "widgetCalories":     return Spec(valueSrc: "cal", iconName: "icCalories", ringSrc: "cal")
        case "widgetActiveMins":   return Spec(valueSrc: "actmin", iconName: "icActiveMins", ringSrc: "actmin")
        case "widgetWeather":      return Spec(valueSrc: "wtemp", dynIconSrc: "wcond")
        case "widgetChanceOfRain": return Spec(valueSrc: "wrain", iconName: "icRainChance")
        case "widgetUV":           return Spec(valueSrc: "wuv")
        case "widgetSpO2":         return Spec(valueSrc: "spo2", iconName: "icSpO2")
        // widget2ndTZ / widgetCustom are v2 (world clock offset baking / pushed
        // static text) — skipped here so they neither ship a stale GB blob nor
        // crash the face.
        default:                   return Spec()
        }
    }

    /// The full generation result consumed by WappBuilder.
    struct Result {
        var layout: [[String: Any]]        // node tree → packed as `layoutName`
        var fields: [String: Any]          // customFace field map
        var widgetMeta: [[String: Any]]    // compact per-widget metadata for re-edit round-trip
        var textLayerMeta: [[String: Any]] // compact dynamic-text-layer metadata for preview round-trip
        var iconAssets: Set<String>        // exact icon .rle names the layout references (to pack)
        var glyphImages: [(name: String, rle: Data)]  // baked custom-font glyph RLEs to pack
    }

    static func generate(for design: WatchfaceDesign) -> Result {
        var nodes: [[String: Any]] = []
        var text: [[String: Any]] = []
        var rings: [[String: Any]] = []
        var icons: [[String: Any]] = []
        var meta: [[String: Any]] = []
        var iconAssets: Set<String> = []
        var glyphFields: [[String: Any]] = []
        var glyphImages: [(name: String, rle: Data)] = []
        var needsDays = false
        var needsConds = false

        var nextID = 0
        func id() -> Int { let v = nextID; nextID += 1; return v }

        let root = id()
        nodes.append([
            "id": root, "type": "container", "direction": 0,
            "main_alignment": 0, "cross_alignment": 0,
            "dimension": ["type": "rigid", "width": canvas, "height": canvas],
            "placement": ["type": "absolute", "left": 0, "top": 0],
            "visible": true, "inversion": false,
        ])
        // Background is the RLE image (see ImageEncoder.backgroundRLE) — the
        // layout image node draws RLE, not the raw base-layer format.
        nodes.append([
            "id": id(), "parent_id": root, "type": "image",
            "image_name": "background", "draw_mode": 1,
            "placement": ["type": "absolute", "left": 0, "top": 0],
            "visible": true, "inversion": false,
        ])

        // --- complications ---
        for (i, widget) in design.widgets.enumerated() {
            let s = spec(for: widget.type)
            let ink = widget.color == 0 ? 3 : 0    // 0=white ink→level 3, 1=black→0
            let cx = widget.x, cy = widget.y

            let dark = widget.color == 1
            let iconSuffix = dark ? "B" : ""

            meta.append([
                "type": widget.type, "x": cx, "y": cy, "color": widget.color,
                "bg": widget.background, "goal_ring": widget.wantsGoalRing,
                "solid": widget.wantsSolidFill, "show_icon": widget.wantsIcon,
            ])

            if let rleName = widget.backgroundRLEName {
                nodes.append([
                    "id": id(), "parent_id": root, "type": "image",
                    "image_name": rleName, "draw_mode": 1,
                    "placement": ["type": "absolute", "left": cx - widgetBox / 2, "top": cy - widgetBox / 2],
                    "visible": true, "inversion": false,
                ])
            }

            if widget.wantsGoalRing, let ringSrc = s.ringSrc {
                let ph = "r\(i)"
                rings.append(["ph": ph, "src": ringSrc])
                nodes.append([
                    "id": id(), "parent_id": root, "type": "arc",
                    "color": ink, "is_filled": false,
                    "placement": ["type": "absolute"],
                    "arc_info": [
                        "center_x": cx, "center_y": cy, "radius": ringRadius,
                        "border_width": ringBorder, "start_angle": 0, "end_angle": "#\(ph)",
                    ],
                    "visible": true, "inversion": false,
                ])
            }

            let hasIcon = widget.wantsIcon && (s.iconName != nil || s.dynIconSrc != nil)

            // Icon (nudged 3px down from the box top), above the value. Static
            // icons use the color-matched asset; dynamic icons (weather/battery)
            // resolve their name on-watch and take the whole family in that color.
            if hasIcon {
                let imageName: String
                if let dyn = s.dynIconSrc {
                    imageName = "#c\(i)"
                    icons.append(["ph": "c\(i)", "src": dyn, "dark": dark])
                    iconAssets.formUnion(dynamicIconFamily(dyn).map { $0 + iconSuffix })
                } else {
                    imageName = s.iconName! + iconSuffix
                    iconAssets.insert(imageName)
                }
                nodes.append([
                    "id": id(), "parent_id": root, "type": "image",
                    "image_name": imageName, "draw_mode": 1,
                    "placement": ["type": "absolute", "left": cx - iconBox / 2, "top": cy - iconBox + 2],
                    "visible": true, "inversion": false,
                ])
            }

            // A centered text line whose glyphs sit centered on `centerY`.
            func addLine(_ ph: String, src: String, ppem: Int, ascent: Int, descent: Int, centerY: Int) {
                text.append(["ph": ph, "src": src])
                if src == "day" { needsDays = true }
                let height = 26
                let container = id()
                nodes.append([
                    "id": container, "parent_id": root, "type": "container",
                    "direction": 0, "main_alignment": 1, "cross_alignment": 1,
                    "dimension": ["type": "rigid", "width": widgetBox, "height": height],
                    "placement": ["type": "absolute", "left": cx - widgetBox / 2, "top": centerY - height / 2],
                    "visible": true, "inversion": false,
                ])
                nodes.append(textNode(id: id(), parent: container, placeholder: ph,
                                      ppem: ppem, ascent: ascent, descent: descent, color: ink))
            }

            if widget.type == "widgetDate" {
                // Day number above the weekday, the pair centered in the circle
                // (matching the stock date complication).
                addLine("v\(i)", src: "date", ppem: 20, ascent: 13, descent: 3, centerY: cy - 11)
                addLine("w\(i)", src: "day", ppem: 15, ascent: 10, descent: 3, centerY: cy + 11)
            } else if let src = s.valueSrc {
                // Under the icon when shown, otherwise centered in the circle.
                addLine("v\(i)", src: src, ppem: valuePpem, ascent: valueAscent, descent: valueDescent,
                        centerY: hasIcon ? cy + 11 : cy)
            }
        }

        // --- dynamic text layers (live value in the user's custom font) ---
        // The firmware has no font loader, so a custom font is drawn from a
        // pre-baked per-character glyph atlas (GlyphAtlas): one image node per
        // character slot, whose image_name / left / visible customFace fills at
        // runtime. Slots = the source's max character count, so short values
        // (HR, weekday) stay cheap against the node budget. Falls back to the
        // firmware-font text node if the atlas can't be built. Static layers
        // (valueSource == nil) are still baked into the background image.
        var layerIndex = 0
        var textLayerMeta: [[String: Any]] = []
        for layer in design.textLayers {
            guard let source = layer.valueSource else { continue }
            let li = layerIndex
            layerIndex += 1
            let pre = "t\(li)"
            let jsSrc = canonicalSrc(source)   // customFace's src name (weather uses wcond/wrain/wuv)
            if source == .weekday { needsDays = true }
            if source == .weatherCondition { needsConds = true }
            let ppem = max(8, Int(layer.fontSize.rounded()))
            textLayerMeta.append([
                "src": source.rawValue, "x": layer.x, "y": layer.y,
                "w": min(canvas, ppem * source.maxCharacters), "h": ppem + 6,
                "color": layer.shade >= 2 ? 0 : 1,
            ])

            guard let cell = GlyphAtlas.cells(for: layer, layerIndex: li), !cell.glyphs.isEmpty else {
                // Fallback: firmware-font text node (no custom font).
                text.append(["ph": pre, "src": jsSrc])
                let h = ppem + 6
                let w = min(canvas, ppem * source.maxCharacters)
                let container = id()
                nodes.append([
                    "id": container, "parent_id": root, "type": "container",
                    "direction": 0, "main_alignment": 1, "cross_alignment": 1,
                    "dimension": ["type": "rigid", "width": w, "height": h],
                    "placement": ["type": "absolute", "left": layer.x - w / 2, "top": layer.y - h / 2],
                    "visible": true, "inversion": false,
                ])
                nodes.append(textNode(id: id(), parent: container, placeholder: pre,
                                      ppem: ppem, ascent: Int(Double(ppem) * 0.7),
                                      descent: Int(Double(ppem) * 0.15),
                                      color: Int(min(max(layer.shade, 0), 3))))
                continue
            }

            let slots = source.maxCharacters
            let top = layer.y - cell.height / 2
            for slot in 0..<slots {
                nodes.append([
                    "id": id(), "parent_id": root, "type": "image",
                    "image_name": "#\(pre)g\(slot)", "draw_mode": 1,
                    "placement": ["type": "absolute", "left": "#\(pre)x\(slot)", "top": top],
                    "visible": "#\(pre)v\(slot)", "inversion": false,
                ])
            }
            for glyph in cell.glyphs { glyphImages.append((glyph.name, glyph.rle)) }
            var cw: [String: Int] = [:]
            for glyph in cell.glyphs { cw[glyph.code] = glyph.width }
            glyphFields.append([
                "pre": pre, "src": jsSrc, "slots": slots,
                "cx": layer.x, "cell_w": cell.width, "cw": cw,
                "fb": pre + (cell.glyphs.first?.code ?? "0"),   // baked name for hidden/empty slots
                "align": "center",
            ])
        }

        var fields: [String: Any] = [:]
        fields["layout_name"] = layoutName
        fields["full_every"] = 15
        fields["text"] = text
        fields["rings"] = rings
        fields["icons"] = icons
        fields["glyphs"] = glyphFields
        if needsDays {
            fields["days"] = WatchfaceValueSource.weekdayNames()
        }
        if needsConds {
            fields["conds"] = WatchfaceValueSource.weatherConditionNames()
        }

        return Result(layout: nodes, fields: fields, widgetMeta: meta,
                      textLayerMeta: textLayerMeta, iconAssets: iconAssets,
                      glyphImages: glyphImages)
    }

    /// customFace's `text_value` source name for a value source. The weather
    /// text sources' persisted rawValues (`wicon`/`rain`/`uv`) differ from the
    /// engine's canonical names (`wcond`/`wrain`/`wuv`) that complications and
    /// `uses_weather` already use — normalize so a weather *text layer* matches.
    private static func canonicalSrc(_ source: WatchfaceValueSource) -> String {
        switch source {
        case .weatherCondition: return "wcond"
        case .chanceOfRain:     return "wrain"
        case .uvIndex:          return "wuv"
        default:                return source.rawValue
        }
    }

    /// The full icon-asset family a dynamic-icon source can resolve to on-watch
    /// (base names; the color suffix is added by the caller) — so WappBuilder
    /// packs every image the JS might name.
    private static func dynamicIconFamily(_ src: String) -> [String] {
        switch src {
        case "bstate": return ["icBattery", "icBattCharging", "icBattEmpty"]
        case "wcond":  return ["icWthClearDay", "icWthClearNite", "icWthCloudy",
                               "icWthPartCloudyDay", "icWthPartCloudyNite", "icWthRainy",
                               "icWthSnowy", "icWthStormy", "icWthWindy"]
        default:       return []
        }
    }

    private static func textNode(id: Int, parent: Int, placeholder: String,
                                 ppem: Int, ascent: Int, descent: Int, color: Int) -> [String: Any] {
        [
            "id": id, "parent_id": parent, "type": "text",
            "text": "#\(placeholder)", "ppem": ppem, "ascent": ascent, "descent": descent,
            "color": color, "placement": ["type": "relative"],
            "visible": true, "inversion": false,
        ]
    }
}
