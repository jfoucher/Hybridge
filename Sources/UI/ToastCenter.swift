import SwiftUI
import UIKit

/// App-wide transient status banners. Success confirmations auto-dismiss after
/// a couple of seconds; errors linger a little longer. This replaces the old
/// per-view `statusText` labels that stayed on screen indefinitely, so every
/// syncing action across the app reports completion the same way.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        enum Style { case success, error }
        let id = UUID()
        let style: Style
        let text: String
    }

    @Published private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func success(_ text: String) { show(Toast(style: .success, text: text)) }
    func error(_ text: String) { show(Toast(style: .error, text: text)) }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.easeInOut(duration: 0.25)) { current = nil }
    }

    private func show(_ toast: Toast) {
        dismissTask?.cancel()
        withAnimation(.spring(duration: 0.3)) { current = toast }
        let seconds: Double = toast.style == .error ? 4 : 2.5
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}

/// Hosts toast banners in their own `UIWindow` above the whole UIKit
/// controller stack, rather than as a SwiftUI `.overlay()` on the root view.
/// An overlay on the root view is confined to *that view controller's*
/// layer, so it renders *behind* anything presented modally above it —
/// `WatchManageSheet` (tap the dashboard's watch image), Settings, Alarms,
/// and every other screen call `ToastCenter.shared` expecting the banner to
/// be visible no matter what sheet is currently on top. A dedicated
/// alert-level window sits above all of them regardless of presentation
/// depth.
@MainActor
enum ToastWindowController {
    private static var window: PassthroughWindow?

    /// Idempotent — call from wherever a window scene first becomes
    /// available (app is single-window-scene, so "the first one" is fine).
    static func attach(to scene: UIWindowScene) {
        guard window == nil else { return }
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isHidden = false
        let host = UIHostingController(rootView: ToastOverlayRoot())
        host.view.backgroundColor = .clear
        window.rootViewController = host
        Self.window = window
    }
}

/// Only the toast banner itself should intercept touches; everywhere else in
/// this window must fall through to whatever is presented underneath.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event), hit != rootViewController?.view else { return nil }
        return hit
    }
}

private struct ToastOverlayRoot: View {
    @ObservedObject private var center = ToastCenter.shared

    var body: some View {
        VStack {
            if let toast = center.current {
                ToastBanner(toast: toast)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { center.dismiss() }
            }
            Spacer()
        }
        .animation(.spring(duration: 0.3), value: center.current)
    }
}

private struct ToastBanner: View {
    let toast: ToastCenter.Toast

    private var isError: Bool { toast.style == .error }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Capsule().fill(isError ? Color.red : Color.green))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }
}
