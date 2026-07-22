import Foundation
import UIKit

/// Reads a .wapp container downloaded back from the watch — the counterpart of
/// WappBuilder. Parses the container's section format and decodes the 2-bit
/// RAW background image; both are hardware facts. Only
/// what the dashboard preview needs: locating a file inside the icons section
/// and decoding the background image.
enum WappReader {
    static let maxContainerSize = 4 * 1024 * 1024

    /// Validates the transport envelope, CRC and monotonically ordered section
    /// offsets before imported bytes are parsed or uploaded.
    static func isValidContainer(_ data: Data) -> Bool {
        guard data.count >= 92, data.count <= maxContainerSize,
              data.u16LE(at: 0) == FossilFileHandle.appCode.rawValue,
              data.u32LE(at: 4) == 0 else { return false }
        let payloadLength = Int(data.u32LE(at: 8))
        guard payloadLength >= 76, 12 + payloadLength + 4 == data.count,
              [UInt8(1), UInt8(2)].contains(data.u8(at: 12)) else { return false }
        let payload = data.slice(12, payloadLength)
        guard data.u32LE(at: 12 + payloadLength) == Checksums.crc32c(payload) else { return false }

        let offsets = [24, 28, 32, 36, 40, 44, 48].map { Int(data.u32LE(at: $0)) }
        guard offsets[0] >= 88, offsets.last == 12 + payloadLength else { return false }
        return zip(offsets, offsets.dropFirst()).allSatisfy { $0 <= $1 }
    }

    /// Decodes the 240×240 background of a watchface .wapp (raw file as
    /// downloaded, 12-byte transport header included — section offsets are
    /// absolute from byte 0). Returns nil for apps or foreign faces without
    /// a background.raw / background image.
    static func backgroundImage(fromWapp data: Data) -> UIImage? {
        // Inner header: offsets table sits at byte 24 (12-byte transport
        // header + type/version/nulls), see WappBuilder.assembleWapp.
        guard data.count > 52 else { return nil }
        let iconsStart = Int(data.u32LE(at: 28))
        let layoutStart = Int(data.u32LE(at: 32))
        guard iconsStart >= 52, iconsStart < layoutStart, layoutStart <= data.count else { return nil }

        let raw = fileContents(in: data, from: iconsStart, to: layoutStart, named: "background.raw")
            ?? fileContents(in: data, from: iconsStart, to: layoutStart, named: "background")
        guard let raw else { return nil }
        return decodeRAW240(raw)
    }

    /// Extracts the complications declared in the "customWatchFace" config
    /// JSON (written by WappBuilder.configurationJSON) so previews can draw
    /// them. Foreign faces without that config entry return [].
    static func widgets(fromWapp data: Data) -> [WatchfacePreviewRenderer.Widget] {
        guard data.count > 52 else { return [] }
        let configStart = Int(data.u32LE(at: 44))
        let fileEnd = Int(data.u32LE(at: 48))
        guard configStart >= 52, configStart <= fileEnd, fileEnd <= data.count else { return [] }
        guard var json = fileContents(in: data, from: configStart, to: fileEnd, named: "customWatchFace")
        else { return [] }
        if json.last == 0 { json = json.dropLast() }   // stored null-terminated
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return [] }
        // customFace faces carry a compact "widgets" metadata array. Fall back
        // to the legacy comp-layout parse for foreign / older-build faces.
        if let meta = root["widgets"] as? [[String: Any]] {
            return meta.compactMap { m in
                guard let type = m["type"] as? String,
                      let x = m["x"] as? Int, let y = m["y"] as? Int else { return nil }
                return WatchfacePreviewRenderer.Widget(
                    type: type, x: x, y: y,
                    color: (m["color"] as? Int) ?? 0,
                    background: m["bg"] as? String ?? "",
                    goalRing: (m["goal_ring"] as? Bool) ?? false,
                    solidFill: (m["solid"] as? Bool) ?? false)
            }
        }
        guard let layout = root["layout"] as? [[String: Any]] else { return [] }
        return layout.compactMap { element in
            guard element["type"] as? String == "comp",
                  var type = element["name"] as? String,
                  let pos = element["pos"] as? [String: Any],
                  let x = pos["x"] as? Int, let y = pos["y"] as? Int
            else { return nil }
            // Ring-enabled widgets are separate "<type>R" code variants.
            var goalRing = false
            if type.hasSuffix("R"), WidgetCatalog.supportsGoalRing(String(type.dropLast())) {
                goalRing = true
                type = String(type.dropLast())
            }
            // Faces built by older app versions carried a flag instead.
            if (element["goal_ring"] as? Bool) == true
                || ((element["data"] as? [String: Any])?["goal_ring"] as? Bool) == true {
                goalRing = true
            }
            var background = element["bg"] as? String ?? ""
            // "widget_bg_thin_circle_fill0.rle" → "widget_bg_thin_circle" + fill
            if let suffix = background.range(of: "[01]\\.rle$", options: .regularExpression) {
                background.removeSubrange(suffix)
            }
            var solidFill = false
            if background == "wbg_solid" || background == "widget_bg_solid" {
                solidFill = true
                background = ""
            } else if background.hasSuffix("_fill") {
                solidFill = true
                background = String(background.dropLast("_fill".count))
                    .replacingOccurrences(of: "wbg_", with: "widget_bg_")
            }
            return WatchfacePreviewRenderer.Widget(
                type: type, x: x, y: y,
                color: element["color"] as? String == "black" ? 1 : 0,
                background: background,
                goalRing: goalRing,
                solidFill: solidFill)
        }
    }

    /// Dynamic text layers ("widgetText*" comp elements, WappBuilder's own
    /// output) declared in an installed face's config, so the dashboard
    /// preview of a downloaded .wapp can show a representative value. The
    /// real font/size baked into the glyph images isn't recoverable from the
    /// container — only a source + box are — so the preview approximates
    /// with a bold system font sized to the box height.
    static func textLayers(fromWapp data: Data) -> [WatchfacePreviewRenderer.TextPreview] {
        guard data.count > 52 else { return [] }
        let configStart = Int(data.u32LE(at: 44))
        let fileEnd = Int(data.u32LE(at: 48))
        guard configStart >= 52, configStart <= fileEnd, fileEnd <= data.count else { return [] }
        guard var json = fileContents(in: data, from: configStart, to: fileEnd, named: "customWatchFace")
        else { return [] }
        if json.last == 0 { json = json.dropLast() }
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return [] }
        // customFace faces carry a compact "text_layers" metadata array. Fall
        // back to the legacy widgetText comp-layout parse for older faces.
        if let meta = root["text_layers"] as? [[String: Any]] {
            return meta.compactMap { m in
                guard let srcRaw = m["src"] as? String,
                      let source = WatchfaceValueSource(rawValue: srcRaw),
                      let x = m["x"] as? Int, let y = m["y"] as? Int,
                      let h = m["h"] as? Int else { return nil }
                return WatchfacePreviewRenderer.TextPreview(
                    x: x, y: y, w: m["w"] as? Int ?? h, h: h, source: source,
                    color: (m["color"] as? Int) ?? 0)
            }
        }
        guard let layout = root["layout"] as? [[String: Any]] else { return [] }
        // One comp element per dynamic layer (widgetText<index>), each with
        // its own data.src + pos + box. One TextPreview per element.
        return layout.compactMap { element in
            guard element["type"] as? String == "comp",
                  let name = element["name"] as? String, name.hasPrefix("widgetText"),
                  let pos = element["pos"] as? [String: Any],
                  let x = pos["x"] as? Int, let y = pos["y"] as? Int,
                  let size = element["size"] as? [String: Any],
                  let h = size["h"] as? Int,
                  let elementData = element["data"] as? [String: Any],
                  let srcRaw = elementData["src"] as? String,
                  let source = WatchfaceValueSource(rawValue: srcRaw)
            else { return nil }
            let w = size["w"] as? Int ?? h
            return WatchfacePreviewRenderer.TextPreview(
                x: x, y: y, w: w, h: h, source: source,
                color: element["color"] as? String == "black" ? 1 : 0)
        }
    }

    /// The raw customWatchFace config JSON (null terminator stripped).
    static func configJSON(fromWapp data: Data) -> String? {
        guard data.count > 52 else { return nil }
        let configStart = Int(data.u32LE(at: 44))
        let fileEnd = Int(data.u32LE(at: 48))
        guard configStart >= 52, configStart <= fileEnd, fileEnd <= data.count else { return nil }
        guard var json = fileContents(in: data, from: configStart, to: fileEnd, named: "customWatchFace")
        else { return nil }
        if json.last == 0 { json = json.dropLast() }
        return String(data: json, encoding: .utf8)
    }

    /// Reads a .wapp's type and app name without installing it. The type byte
    /// at absolute offset 12 is 0x01 for a watchface, 0x02 for an app (GB
    /// FossilFileReader). The name comes from the displayName section's
    /// "display_name" string entry. Used to detect stale same-name installs
    /// and to decide whether to theme-activate after upload.
    static func metadata(fromWapp data: Data) -> (name: String, isWatchface: Bool)? {
        guard isValidContainer(data) else { return nil }
        let isWatchface = data.u8(at: 12) != 0x02
        let displayNameStart = Int(data.u32LE(at: 36))
        let configStart = Int(data.u32LE(at: 44))
        guard displayNameStart >= 52, displayNameStart <= configStart, configStart <= data.count
        else { return nil }
        guard let name = fileContents(in: data, from: displayNameStart, to: configStart, named: "display_name")
        else { return nil }
        // Stored null-terminated, and some apps add a trailing newline; trim both.
        guard let string = String(data: name, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)),
              !string.isEmpty else { return nil }
        return (string, isWatchface)
    }

    /// A one-line blurb for face lists, from an optional "description" entry
    /// in the displayName section (written by the faces/ build.py). Faces
    /// that don't carry one — anything from Fossil, or built before this —
    /// return nil.
    static func description(fromWapp data: Data) -> String? {
        guard data.count > 52 else { return nil }
        let displayNameStart = Int(data.u32LE(at: 36))
        let configStart = Int(data.u32LE(at: 44))
        guard displayNameStart >= 52, displayNameStart <= configStart, configStart <= data.count
        else { return nil }
        guard let blob = fileContents(in: data, from: displayNameStart, to: configStart, named: "description"),
              let string = String(data: blob, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines)),
              !string.isEmpty
        else { return nil }
        return string
    }

    /// The wapp's identifier — the name of the first entry in the code
    /// section (e.g. "stopwatchApp"). This is the name the watch reports in
    /// its installed-apps list, which can differ from the display_name
    /// (e.g. dakhnod-SDK apps: identifier "stopwatchApp", display name
    /// "Moon Phase").
    static func identifier(fromWapp data: Data) -> String? {
        guard data.count > 52 else { return nil }
        let codeStart = Int(data.u32LE(at: 24))
        let iconsStart = Int(data.u32LE(at: 28))
        guard codeStart >= 52, codeStart < iconsStart, iconsStart <= data.count else { return nil }
        let nameLength = Int(data.u8(at: codeStart))       // includes null
        guard nameLength > 1, codeStart + 1 + nameLength <= iconsStart else { return nil }
        return String(data: data.slice(codeStart + 1, nameLength - 1), encoding: .utf8)
    }

    /// Walks a filename section ([len][name\0][u16 size][data] entries) and
    /// returns the contents of `named`, or nil.
    private static func fileContents(in data: Data, from start: Int, to end: Int, named: String) -> Data? {
        var offset = start
        while offset + 4 <= end {
            let nameLength = Int(data.u8(at: offset))          // includes null
            guard nameLength > 0, offset + 1 + nameLength + 2 <= end else { return nil }
            let name = String(data: data.slice(offset + 1, nameLength - 1), encoding: .utf8) ?? ""
            offset += 1 + nameLength
            let size = Int(data.u16LE(at: offset))
            offset += 2
            guard offset + size <= end else { return nil }
            if name == named {
                return data.slice(offset, size)
            }
            offset += size
        }
        return nil
    }

    /// 2-bit raw image: 4 pixels per byte, high bits first, stored starting
    /// at the bottom-right pixel going backwards (GB decodeFromRAWImage).
    private static func decodeRAW240(_ raw: Data) -> UIImage? {
        let width = 240, height = 240
        guard raw.count * 4 == width * height else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        var index = width * height - 1
        for byte in raw {
            for shift in stride(from: 6, through: 0, by: -2) {
                guard index >= 0 else { break }
                pixels[index] = ((byte >> shift) & 0x03) * 85
                index -= 1
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 8,
                                    bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
