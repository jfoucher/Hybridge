import Foundation

/// Routes a `.hbface` package opened via Files/Messages/AirDrop (`onOpenURL`
/// in HybridgeApp) to the Watchfaces tab, even when it isn't the one on
/// screen. `RootTabView` switches to the Faces tab when this becomes
/// non-nil (or clears it with an error toast if the active watch has no
/// e-ink display); `WatchfacesView` consumes it through the same import path
/// the file-importer button uses, then clears it.
@MainActor
final class WatchfaceImportRouter: ObservableObject {
    static let shared = WatchfaceImportRouter()
    @Published var pendingImportURL: URL?
    private init() {}
}
