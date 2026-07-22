import Foundation
import CoreTransferable
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum BoundedImageImportError: LocalizedError {
    case tooLarge
    case invalidImage
    case excessiveDimensions
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .tooLarge: return String(localized: "The selected image is larger than 20 MB")
        case .invalidImage: return String(localized: "The selected file is not a valid image")
        case .excessiveDimensions: return String(localized: "The selected image dimensions are too large")
        case .outputTooLarge: return String(localized: "The processed image is too large")
        }
    }
}

/// Photos transfer that inspects the provider-backed file before reading it,
/// then down-samples at decode time. Full-resolution camera images never
/// become UIImages in the app process.
struct BoundedPhotoTransfer: Transferable, Sendable {
    static let maximumCompressedBytes: Int64 = 20 * 1024 * 1024
    static let maximumSourcePixels: Int64 = 40_000_000
    static let maximumWorkingDimension = 2048

    let pngData: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let values = try received.file.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? 0) <= maximumCompressedBytes else {
                throw BoundedImageImportError.tooLarge
            }
            let data = try Data(contentsOf: received.file,
                                options: [.mappedIfSafe, .uncached])
            guard Int64(data.count) <= maximumCompressedBytes else {
                throw BoundedImageImportError.tooLarge
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw BoundedImageImportError.invalidImage
            }
            let pixels = width.int64Value.multipliedReportingOverflow(by: height.int64Value)
            guard !pixels.overflow, pixels.partialValue <= maximumSourcePixels else {
                throw BoundedImageImportError.excessiveDimensions
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumWorkingDimension,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                                     options as CFDictionary),
                  let png = UIImage(cgImage: cgImage).pngData() else {
                throw BoundedImageImportError.invalidImage
            }
            guard Int64(png.count) <= maximumCompressedBytes else {
                throw BoundedImageImportError.outputTooLarge
            }
            return BoundedPhotoTransfer(pngData: png)
        }
    }
}

/// Cancellable, utility-priority rendering for the editor. Only immutable
/// PNG bytes and scalar geometry cross the task boundary; UIKit/Core Image
/// temporaries live inside an autorelease pool and never become view state.
enum BoundedImageProcessor {
    private static let targetSide: CGFloat = 480
    private static let maximumRenderedBytes = 2 * 1024 * 1024

    static func preview(sourcePNG: Data, contrast: Double) async throws -> Data {
        let work = Task.detached(priority: .utility) {
            try autoreleasepool {
                try Task.checkCancellation()
                guard let image = UIImage(data: sourcePNG) else {
                    throw BoundedImageImportError.invalidImage
                }
                let adjusted = ImageEncoder.applyContrast(image, contrast: contrast)
                try Task.checkCancellation()
                guard let preview = ImageEncoder.quantizedPreview(from: adjusted),
                      let png = preview.pngData() else {
                    throw BoundedImageImportError.invalidImage
                }
                guard png.count <= maximumRenderedBytes else {
                    throw BoundedImageImportError.outputTooLarge
                }
                return png
            }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static func background(sourcePNG: Data, contrast: Double, scale: CGFloat,
                           offset: CGSize, previewSize: CGFloat) async throws -> Data {
        let work = Task.detached(priority: .utility) {
            try autoreleasepool {
                try Task.checkCancellation()
                guard previewSize > 0, scale.isFinite, scale > 0,
                      offset.width.isFinite, offset.height.isFinite,
                      let image = UIImage(data: sourcePNG) else {
                    throw BoundedImageImportError.invalidImage
                }
                let adjusted = ImageEncoder.applyContrast(image, contrast: contrast)
                try Task.checkCancellation()

                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let renderer = UIGraphicsImageRenderer(
                    size: CGSize(width: targetSide, height: targetSide), format: format)
                let ratio = targetSide / previewSize
                let rendered = renderer.image { context in
                    let cgContext = context.cgContext
                    cgContext.translateBy(x: targetSide / 2 + offset.width * ratio,
                                          y: targetSide / 2 + offset.height * ratio)
                    cgContext.scaleBy(x: scale, y: scale)
                    let aspect = adjusted.size.width / adjusted.size.height
                    let width = aspect > 1 ? targetSide * aspect : targetSide
                    let height = aspect > 1 ? targetSide : targetSide / aspect
                    adjusted.draw(in: CGRect(x: -width / 2, y: -height / 2,
                                             width: width, height: height))
                }
                try Task.checkCancellation()
                guard let png = rendered.pngData() else {
                    throw BoundedImageImportError.invalidImage
                }
                guard png.count <= maximumRenderedBytes else {
                    throw BoundedImageImportError.outputTooLarge
                }
                return png
            }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
