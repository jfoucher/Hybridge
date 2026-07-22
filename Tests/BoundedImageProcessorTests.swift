import XCTest
import UIKit
@testable import Hybridge

final class BoundedImageProcessorTests: XCTestCase {
    @MainActor
    private func png(width: Int, height: Int, alpha: CGFloat = 1) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = alpha == 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { context in
            UIColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }

    @MainActor
    func testBackgroundBoundsExtremeAspectRatioAndOutputDimensions() async throws {
        let source = try png(width: 1_500, height: 24, alpha: 0.5)
        let output = try await BoundedImageProcessor.background(
            sourcePNG: source, contrast: 1.5, scale: 1.2,
            offset: CGSize(width: 8, height: -4), previewSize: 240)
        let image = try XCTUnwrap(UIImage(data: output)?.cgImage)
        XCTAssertEqual(image.width, 480)
        XCTAssertEqual(image.height, 480)
        XCTAssertLessThanOrEqual(output.count, 2 * 1024 * 1024)
    }

    @MainActor
    func testPreviewRejectsCorruptData() async {
        do {
            _ = try await BoundedImageProcessor.preview(
                sourcePNG: Data("not an image".utf8), contrast: 1)
            XCTFail("corrupt input was accepted")
        } catch {
            XCTAssertTrue(error is BoundedImageImportError)
        }
    }

    @MainActor
    func testSupersededPreviewCanBeCancelled() async throws {
        let source = try png(width: 2_048, height: 2_048)
        let task = Task {
            try await BoundedImageProcessor.preview(sourcePNG: source, contrast: 1.8)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled render completed")
        } catch is CancellationError {
            // Expected: a cancelled preview never publishes stale output.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }
}
