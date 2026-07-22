import UIKit

/// Bakes the per-character glyph images a dynamic text layer needs into the
/// watch's RLE icon format, in the layer's chosen font/size/shade. The watch
/// firmware has no font loader — this is what makes a custom font possible
/// at all for a value it fills in itself at runtime (see widget_text.js):
/// the phone bakes every character the value could ever contain, and the
/// watch just picks which pre-baked images to show.
enum GlyphAtlas {

    struct Glyph {
        /// widget_text.js char_code — the character itself, or the short
        /// letter code for symbols.
        let code: String
        /// Icons-section name, e.g. "t0c" (layer 0, comma).
        let name: String
        let rle: Data
        /// Natural advance width in px, shipped as data.cw — the pen step
        /// widget_text.js uses between characters. The RLE image itself is
        /// baked at the *shared* Cell.width with the ink centered: sibling
        /// image nodes with unequal dimensions shear into diagonal streaks
        /// on the watch (the "MER shows 777" bug — uniform boxes are the
        /// only configuration ever proven on hardware), so proportional
        /// spacing comes entirely from positioning, never from the box.
        let width: Int
    }

    /// One layer's full glyph set: every glyph baked into the same
    /// width × height box (widest advance × line height), plus per-glyph
    /// natural advances for proportional positioning.
    struct Cell {
        /// The uniform box width (widest advance in the charset).
        let width: Int
        let height: Int
        let glyphs: [Glyph]
    }

    /// nil for static layers (valueSource == nil) or a font that can't be
    /// resolved. `layerIndex` is the layer's position among dynamic layers
    /// only (WappBuilder.dynamicTextLayers) — it feeds both the asset-name
    /// prefix and the widgetText<i> code-entry index.
    static func cells(for layer: WatchfaceTextLayer, layerIndex: Int) -> Cell? {
        guard let source = layer.valueSource else { return nil }
        let font = layer.uiFont(scale: 1)
        let charset = source.charset
        let height = max(Int(font.lineHeight.rounded(.up)), 1)

        let advances = charset.map { ch -> Int in
            let advance = NSAttributedString(string: String(ch), attributes: [.font: font]).size().width
            return max(Int(advance.rounded(.up)), 1)
        }
        let cellWidth = advances.max() ?? 1
        let glyphs = zip(charset, advances).map { ch, advance -> Glyph in
            Glyph(code: assetCode(for: ch),
                  name: "t\(layerIndex)\(assetCode(for: ch))",
                  rle: render(ch, font: font, color: layer.uiColor, width: cellWidth, height: height),
                  width: advance)
        }
        return Cell(width: cellWidth, height: height, glyphs: glyphs)
    }

    /// Total RLE bytes a layer's glyph set adds to the .wapp icons section —
    /// the editor surfaces this so the user can see the transfer-size impact
    /// before installing (packets are capped at ATT MTU−3, so this is all
    /// extra round trips, not a hard limit).
    static func totalBytes(for layer: WatchfaceTextLayer, layerIndex: Int) -> Int {
        cells(for: layer, layerIndex: layerIndex)?.glyphs.reduce(0) { $0 + $1.rle.count } ?? 0
    }

    /// Symbols get a short letter code so names stay well under the ~29-byte
    /// icon-name limit (WatchfaceWidget.backgroundRLEName); digits map to
    /// themselves.
    static func assetCode(for ch: Character) -> String {
        switch ch {
        case ",": return "c"
        case "%": return "p"
        case ":": return "n"
        case "/": return "s"
        case "-": return "d"
        case "°": return "g"
        default: return String(ch)
        }
    }

    private static func render(_ ch: Character, font: UIFont, color: UIColor, width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { _ in
            let attributed = NSAttributedString(string: String(ch), attributes: [
                .font: font,
                .foregroundColor: color,
            ])
            let size = attributed.size()
            attributed.draw(at: CGPoint(x: (CGFloat(width) - size.width) / 2,
                                        y: (CGFloat(height) - size.height) / 2))
        }
        guard let pixels = ImageEncoder.pixels(from: image, width: width, height: height) else { return Data() }
        return ImageEncoder.rleImage(from: pixels)
    }
}
