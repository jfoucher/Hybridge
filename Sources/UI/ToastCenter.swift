import SwiftUI

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

extension View {
    /// Presents `ToastCenter.shared` banners over this view.
    func toastOverlay() -> some View { modifier(ToastOverlayModifier()) }
}

private struct ToastOverlayModifier: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = center.current {
                ToastBanner(toast: toast)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { center.dismiss() }
                    // Let touches outside the banner fall through to the UI.
                    .frame(maxWidth: .infinity, alignment: .top)
                    .allowsHitTesting(true)
            }
        }
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
