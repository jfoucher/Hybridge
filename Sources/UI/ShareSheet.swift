import SwiftUI
import UIKit

/// `UIActivityViewController` in SwiftUI clothing. `ShareLink` — used
/// everywhere else in the app — needs its item up front, but a shared face
/// doesn't exist until its `.wapp` has been built, and the swipe gesture is
/// meant to be a single operation: swipe, then the sheet appears on its own.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    /// Called once the sheet goes away, whether or not anything was shared —
    /// the caller uses it to delete the temporary export.
    var onFinish: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
