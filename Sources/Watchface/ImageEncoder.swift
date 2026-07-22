import Foundation
import CoreGraphics
import UIKit

/// Implements the watch's 2-bit grayscale RAW and RLE image formats (a
/// hardware fact).
enum ImageEncoder {

    struct Pixels {
        let width: Int
        let height: Int
        /// RGBA8, row-major from top-left.
        let rgba: [UInt8]

        func gray(atIndex i: Int) -> UInt8 {
            let base = i * 4
            let sum = Int(rgba[base]) + Int(rgba[base + 1]) + Int(rgba[base + 2])
            return UInt8(sum / 3)
        }

        func alpha(atIndex i: Int) -> UInt8 {
            rgba[i * 4 + 3]
        }
    }

    static func pixels(from image: UIImage, width: Int, height: Int) -> Pixels? {
        guard let cgImage = image.cgImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &rgba,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(width: width, height: height, rgba: rgba)
    }

    // MARK: RAW (background.raw): 1 gray byte per pixel in *reverse* order,
    // then packed 4 pixels/byte using the top 2 bits of each.

    static func rawImage(from pixels: Pixels) -> Data {
        let count = pixels.width * pixels.height
        var grayBytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            grayBytes[count - 1 - i] = pixels.gray(atIndex: i)
        }
        var out = Data(count: count / 4)
        for i in 0..<count {
            let shift = 6 - (i % 4) * 2
            out[i / 4] |= (grayBytes[i] >> 6) << shift
        }
        return out
    }

    // MARK: RLE (.rle icons/preview): per-pixel byte (alphaBits<<2 | gray>>6),
    // run-length encoded as (count, value) pairs, wrapped in
    // [width][height][pairs...][FF FF].
    //
    // Header order is width-first — GB's encodeToRLEImage writes height
    // first, but every image GB encodes is square so it can't tell; the
    // firmware's real order shows in the two non-square stock icons
    // (icBattEmpty 33×13, icBattCharging 6×9), which only decode into a
    // coherent picture with byte 0 as the width. Height-first here made
    // non-square glyph cells wrap at the wrong stride on the watch (a
    // diagonal smear where the text should be).

    static func rlePixelBytes(from pixels: Pixels) -> [UInt8] {
        let count = pixels.width * pixels.height
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            var value = pixels.gray(atIndex: i) >> 6
            let alpha = pixels.alpha(atIndex: i)
            value |= ~(alpha >> 4) & 0b0000_1100
            bytes[i] = value
        }
        return bytes
    }

    static func rleEncode(_ data: [UInt8]) -> Data {
        guard !data.isEmpty else { return Data() }
        var out = Data()
        var lastByte = data[0]
        var count = 1
        for byte in data.dropFirst() {
            if byte != lastByte || count >= 255 {
                out.append(UInt8(count))
                out.append(lastByte)
                count = 1
                lastByte = byte
            } else {
                count += 1
            }
        }
        out.append(UInt8(count))
        out.append(lastByte)
        return out
    }

    static func rleImage(from pixels: Pixels) -> Data {
        var out = Data()
        out.append(UInt8(pixels.width))
        out.append(UInt8(pixels.height))
        out.append(rleEncode(rlePixelBytes(from: pixels)))
        out.append(0xFF)
        out.append(0xFF)
        return out
    }

    // MARK: Convenience for watchface assembly

    /// 240×240 2bpp RAW background from any image (center-crop + scale).
    static func backgroundRaw(from image: UIImage) -> Data? {
        guard let pixels = pixels(from: centerCropSquare(image), width: 240, height: 240) else { return nil }
        return rawImage(from: pixels)
    }

    /// 240×240 square RLE background, drawn by the customFace layout's image
    /// node. The layout_parser_json `image` node draws the RLE format (as every
    /// moon-watch face's background does, e.g. simple/'s "bg") forced fully opaque so every
    /// pixel is drawn (the RLE alpha bits mask transparent pixels out).
    static func backgroundRLE(from image: UIImage) -> Data? {
        guard let pixels = pixels(from: flattenOntoBlack(centerCropSquare(image), size: 240),
                                  width: 240, height: 240) else { return nil }
        return rleImage(from: pixels)
    }

    /// 192×192 circular RLE preview from the same source image.
    static func previewRLE(from image: UIImage) -> Data? {
        let squared = centerCropSquare(image)
        let circular = circularImage(squared, size: CGSize(width: 192, height: 192))
        guard let pixels = pixels(from: circular, width: 192, height: 192) else { return nil }
        return rleImage(from: pixels)
    }

    /// 76×76 RLE widget background: optional solid disc under an optional
    /// bundled circle-outline PNG, inverted for the black-on-white widget
    /// variant. The base rendition is for white widgets (black disc, white
    /// outline); `inverted` flips it.
    static func widgetBackgroundRLE(circleNamed circle: String?, solidFill: Bool, inverted: Bool) -> Data? {
        let side = 76
        var circleImage: UIImage?
        if let circle {
            guard let url = Bundle.main.url(forResource: circle, withExtension: "png", subdirectory: "fossil_hr"),
                  let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data)
            else { return nil }
            circleImage = image
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        var image = renderer.image { context in
            if solidFill {
                UIColor.black.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
            }
            circleImage?.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        if inverted {
            image = invert(image) ?? image
        }
        guard let pixels = pixels(from: image, width: side, height: side) else { return nil }
        return rleImage(from: pixels)
    }

    // MARK: Image helpers

    /// Draw an image onto an opaque black square — guarantees no transparent
    /// pixels survive into the RLE (which would be masked out on the watch).
    static func flattenOntoBlack(_ image: UIImage, size: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let side = CGFloat(size)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    static func centerCropSquare(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width
        let height = cgImage.height
        let side = min(width, height)
        let rect = CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
        guard let cropped = cgImage.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: 1, orientation: image.imageOrientation)
    }

    static func circularImage(_ image: UIImage, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            return format
        }())
        return renderer.image { context in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Shared context so the contrast filter doesn't spin up a new GPU
    /// context on every slider tick.
    private static let ciContext = CIContext()

    /// Adjust an image's contrast (1.0 = untouched, >1 punchier, <1 flatter).
    /// Applied before the 2bpp quantization so the user can pull detail out of
    /// a washed-out photo. Returns the input unchanged if the filter fails.
    static func applyContrast(_ image: UIImage, contrast: Double) -> UIImage {
        guard abs(contrast - 1.0) > 0.001 else { return image }
        guard let ciImage = CIImage(image: image),
              let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        guard let output = filter.outputImage,
              let cgImage = ciContext.createCGImage(output, from: ciImage.extent) else { return image }
        return UIImage(cgImage: cgImage)
    }

    static func invert(_ image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image),
              let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Quantized grayscale rendition of an image as the watch will show it —
    /// used for the live editor preview.
    static func quantizedPreview(from image: UIImage, size: Int = 240) -> UIImage? {
        guard let pix = pixels(from: centerCropSquare(image), width: size, height: size) else { return nil }
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<(size * size) {
            let level = pix.gray(atIndex: i) >> 6
            let value: UInt8
            switch level {
            case 0: value = 0
            case 1: value = 85
            case 2: value = 170
            default: value = 255
            }
            rgba[i * 4] = value
            rgba[i * 4 + 1] = value
            rgba[i * 4 + 2] = value
            rgba[i * 4 + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &rgba,
                                      width: size,
                                      height: size,
                                      bitsPerComponent: 8,
                                      bytesPerRow: size * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = context.makeImage()
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
