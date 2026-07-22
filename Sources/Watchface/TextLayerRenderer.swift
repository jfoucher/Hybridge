import UIKit

extension WatchfaceTextLayer {
    /// Font for this layer; `scale` maps face pixels (240×240) to canvas points.
    func uiFont(scale: CGFloat) -> UIFont {
        let points = CGFloat(fontSize) * scale
        if fontFamily.isEmpty {
            return .systemFont(ofSize: points, weight: bold ? .bold : .regular)
        }
        var descriptor = UIFontDescriptor(fontAttributes: [.family: fontFamily])
        if bold, let bolded = descriptor.withSymbolicTraits(.traitBold) {
            descriptor = bolded
        }
        return UIFont(descriptor: descriptor, size: points)
    }

    var uiColor: UIColor {
        UIColor(white: CGFloat(grayValue) / 255, alpha: 1)
    }
}

/// Rasterizes text layers over the background photo. This happens entirely on
/// the phone: the watch just receives the finished 2bpp image, which is what
/// makes arbitrary fonts and rotation possible at all.
enum TextLayerRenderer {

    /// Canvas side used when baking (matches the editor's exported crop; the
    /// 2× headroom over the watch's 240 px keeps glyph edges clean after the
    /// final downscale + quantization).
    static let canvasSide: CGFloat = 480

    /// Square background with all static text layers baked in. Dynamic
    /// layers (valueSource != nil) are skipped — the watch draws those
    /// itself at runtime from a baked glyph atlas (GlyphAtlas) instead.
    /// Returns the input unchanged when there is nothing to draw.
    static func composite(background: UIImage, layers: [WatchfaceTextLayer]) -> UIImage {
        let drawable = layers.filter { !$0.text.isEmpty && $0.valueSource == nil }
        guard !drawable.isEmpty else { return background }

        let squared = ImageEncoder.centerCropSquare(background)
        let side = canvasSide
        let scale = side / 240
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { context in
            squared.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            for layer in drawable {
                let attributed = NSAttributedString(string: layer.text, attributes: [
                    .font: layer.uiFont(scale: scale),
                    .foregroundColor: layer.uiColor,
                ])
                let textSize = attributed.size()
                let cg = context.cgContext
                cg.saveGState()
                cg.translateBy(x: CGFloat(layer.x) * scale, y: CGFloat(layer.y) * scale)
                cg.rotate(by: CGFloat(layer.rotation) * .pi / 180)
                attributed.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
                cg.restoreGState()
            }
        }
    }
}
