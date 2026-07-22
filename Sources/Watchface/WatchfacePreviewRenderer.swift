import UIKit

/// Renders an on-phone approximation of how the watch shows a face: the
/// 2-bit grayscale background with the complications composited on top.
/// Complication artwork comes from the bundled fossil_hr assets — the
/// widget_bg_* circle PNGs and the <type>_preview.png glyphs (white on
/// transparent), tinted to the widget's color.
enum WatchfacePreviewRenderer {

    struct Widget {
        let type: String
        let x: Int
        let y: Int
        let color: Int          // 0 = white, 1 = black
        let background: String  // "" or widget_bg_* base name (no color/.rle)
        var goalRing = false
        var solidFill = false
    }

    /// A dynamic text layer read back from an installed face (WappReader).
    /// The real baked font/size can't be recovered from the .wapp, so the
    /// preview approximates with a bold system font sized to the box.
    struct TextPreview {
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        let source: WatchfaceValueSource
        let color: Int           // 0 = white, 1 = black
    }

    /// Preview of a local design: quantized background + its complications.
    static func render(design: WatchfaceDesign) -> UIImage {
        var background: UIImage?
        if let png = design.backgroundPNG, let image = UIImage(data: png) {
            background = ImageEncoder.quantizedPreview(from: image)
        }
        let widgets = design.widgets.map {
            Widget(type: $0.type, x: $0.x, y: $0.y, color: $0.color, background: $0.background,
                   goalRing: $0.wantsGoalRing, solidFill: $0.wantsSolidFill)
        }
        return render(background: background, widgets: widgets, layers: design.textLayers)
    }

    /// 240×240 composite of a face background (nil = plain black) and its
    /// complications at their designed positions.
    static func render(background: UIImage?, widgets: [Widget], texts: [TextPreview] = [],
                       layers: [WatchfaceTextLayer] = []) -> UIImage {
        let side: CGFloat = 240
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            background?.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            for widget in widgets {
                let size = CGFloat(WatchfaceWidget.size)
                let rect = CGRect(x: CGFloat(widget.x) - size / 2,
                                  y: CGFloat(widget.y) - size / 2,
                                  width: size, height: size)
                let tint: UIColor = widget.color == 0 ? .white : .black
                if widget.solidFill {
                    (widget.color == 0 ? UIColor.black : .white).setFill()
                    context.cgContext.fillEllipse(in: rect)
                }
                if !widget.background.isEmpty, let circle = asset(widget.background) {
                    circle.withTintColor(tint).draw(in: rect)
                }
                if let glyph = asset("\(widget.type)_preview") {
                    glyph.withTintColor(tint).draw(in: rect)
                }
                if widget.goalRing {
                    // Faint full track + representative progress arc (the
                    // watch fills it live from the actual goal progress).
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    let radius = size / 2 - 2
                    let track = UIBezierPath(arcCenter: center, radius: radius,
                                             startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                    track.lineWidth = 3
                    tint.withAlphaComponent(0.35).setStroke()
                    track.stroke()
                    let ring = UIBezierPath(arcCenter: center, radius: radius,
                                            startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
                    ring.lineWidth = 3
                    ring.lineCapStyle = .round
                    tint.setStroke()
                    ring.stroke()
                }
            }
            for text in texts {
                let tint: UIColor = text.color == 0 ? .white : .black
                let font = UIFont.boldSystemFont(ofSize: CGFloat(max(text.h - 2, 8)))
                let attributed = NSAttributedString(string: text.source.sampleText, attributes: [
                    .font: font,
                    .foregroundColor: tint,
                ])
                let textSize = attributed.size()
                attributed.draw(at: CGPoint(x: CGFloat(text.x) - textSize.width / 2,
                                            y: CGFloat(text.y) - textSize.height / 2))
            }
            // Design text layers: static ones show their verbatim text, dynamic
            // ones a sample of the live value. The 240 canvas maps 1:1 to face
            // pixels, so the layer's own font/size/shade/rotation apply as-is.
            for layer in layers {
                let string = layer.valueSource?.sampleText ?? layer.text
                guard !string.isEmpty else { continue }
                let attributed = NSAttributedString(string: string, attributes: [
                    .font: layer.uiFont(scale: 1),
                    .foregroundColor: layer.uiColor,
                ])
                let textSize = attributed.size()
                let cg = context.cgContext
                cg.saveGState()
                cg.translateBy(x: CGFloat(layer.x), y: CGFloat(layer.y))
                cg.rotate(by: CGFloat(layer.rotation) * .pi / 180)
                attributed.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
                cg.restoreGState()
            }
        }
    }

    private static func asset(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "fossil_hr"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return UIImage(data: data)
    }
}
