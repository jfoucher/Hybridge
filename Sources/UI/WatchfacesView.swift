import SwiftUI
import UniformTypeIdentifiers

/// A `.hbface` written to the temp directory, waiting to be handed to the
/// share sheet. Identifiable so `.sheet(item:)` presents it as soon as the
/// build finishes, with no second tap.
private struct ExportedFace: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct WatchfacesView: View {
    @EnvironmentObject var watch: WatchManager
    @StateObject private var importRouter = WatchfaceImportRouter.shared
    @State private var designs: [WatchfaceDesign] = []
    @State private var editorDesign: WatchfaceDesign?
    @State private var busyText: String?
    @State private var installingDesignID: WatchfaceDesign.ID?
    @State private var installingBundledID: BundledFace.ID?
    @State private var sharingDesignID: WatchfaceDesign.ID?
    @State private var exportedFace: ExportedFace?
    @State private var importingFace = false
    @State private var customTextPushTask: Task<Void, Never>?
    // Scoped per watch — @AppStorage can't follow a changing key, so these
    // load/save through WatchScoped and reload on watch switches.
    @State private var customUpper = UserDefaults.standard.string(forKey: WatchScoped.key(.customWidgetUpper)) ?? ""
    @State private var customLower = UserDefaults.standard.string(forKey: WatchScoped.key(.customWidgetLower)) ?? ""

    /// True while any face — a design or a bundled one — is being pushed to the
    /// watch. Only one upload can be in flight, so every Install button disables.
    private var isInstalling: Bool {
        installingDesignID != nil || installingBundledID != nil
    }

    private var activeFaceHasCustomWidget: Bool {
        designs.first { $0.sanitizedName == watch.activeWatchfaceName }?
            .widgets.contains { $0.type == "widgetCustom" } ?? false
    }

    private var installedFaces: [InstalledApp] {
        watch.installedApps.filter(\.isWatchface)
    }

    var body: some View {
        NavigationStack {
            ThemedScreen("Watchfaces") {
                onWatchSection
                myDesignsSection
                if !BundledFaces.all.isEmpty { bundledSection }
                gallerySection
                if activeFaceHasCustomWidget { customWidgetSection }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if designs.isEmpty { designs = await WatchfaceStore.loadAsync() }
                // A cold launch from a .hbface sets the router before this
                // screen exists, so onChange never sees the transition.
                if let url = importRouter.pendingImportURL {
                    importRouter.pendingImportURL = nil
                    importFace(from: url)
                }
            }
            .onChange(of: customUpper) { _, value in
                UserDefaults.standard.set(value, forKey: WatchScoped.key(.customWidgetUpper))
                scheduleCustomTextPush()
            }
            .onChange(of: customLower) { _, value in
                UserDefaults.standard.set(value, forKey: WatchScoped.key(.customWidgetLower))
                scheduleCustomTextPush()
            }
            .onReceive(NotificationCenter.default.publisher(for: .activeWatchChanged)) { _ in
                customUpper = UserDefaults.standard.string(forKey: WatchScoped.key(.customWidgetUpper)) ?? ""
                customLower = UserDefaults.standard.string(forKey: WatchScoped.key(.customWidgetLower)) ?? ""
            }
            .fileImporter(isPresented: $importingFace,
                          allowedContentTypes: [.hybridgeWatchface]) { result in
                if case let .success(url) = result { importFace(from: url) }
            }
            .sheet(item: $exportedFace) { face in
                ShareSheet(url: face.url) {
                    try? FileManager.default.removeItem(at: face.url)
                    exportedFace = nil
                }
            }
            .onChange(of: importRouter.pendingImportURL) { _, url in
                // A .hbface opened from Files/Messages/AirDrop lands here once
                // RootTabView has brought this tab on screen.
                guard let url else { return }
                importRouter.pendingImportURL = nil
                importFace(from: url)
            }
            .fullScreenCover(item: $editorDesign) { design in
                WatchfaceEditorView(design: design) { updated in
                    if let index = designs.firstIndex(where: { $0.id == updated.id }) {
                        designs[index] = updated
                    } else {
                        designs.append(updated)
                    }
                    let snapshot = designs
                    Task {
                        if !(await WatchfaceStore.saveAsync(snapshot)) {
                            ToastCenter.shared.error(String(localized: "Could not save watchface designs"))
                        }
                    }
                }
            }
        }
    }

    // MARK: On the watch

    private var onWatchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("On the watch")
            ThemedCard {
                if installedFaces.isEmpty {
                    emptyLine("No watchfaces listed yet — tap Refresh.")
                }
                ForEach(Array(installedFaces.enumerated()), id: \.element.id) { i, app in
                    let active = app.name == watch.activeWatchfaceName
                    SwipeToDelete(onDelete: {
                        runBusy("Removing \(app.name)…", success: "\(app.name) removed") {
                            try await watch.deleteApp(app)
                        }
                    }) {
                        Button {
                            runBusy("Activating \(app.name)…", success: "\(app.name) activated") {
                                try await watch.activateWatchface(named: app.name)
                            }
                        } label: {
                            HStack(spacing: 14) {
                                EInkThumb()
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).font(Theme.sans(16, weight: .semibold, relativeTo: .body))
                                        .foregroundStyle(Theme.ink)
                                    Text(active ? String(localized: "Active · v\(app.version)")
                                                : String(localized: "v\(app.version)"))
                                        .font(Theme.sans(13, relativeTo: .footnote)).foregroundStyle(Theme.sub)
                                }
                                Spacer()
                                if active {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Theme.success)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableRow())
                        .background(Theme.card)
                    }
                    Hairline(leading: i == installedFaces.count - 1 ? 16 : 80)
                }
                Button {
                    runBusy("Refreshing…", success: "List refreshed") {
                        try await watch.refreshInstalledApps()
                    }
                } label: {
                    brassRow("arrow.clockwise", "Refresh list")
                }.buttonStyle(PressableRow())
            }
        }
    }

    // MARK: My designs

    private var myDesignsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("My designs").padding(.top, 26)
            ThemedCard {
                ForEach(designs) { design in
                    SwipeToDelete(onDelete: {
                        designs.removeAll { $0.id == design.id }
                        let snapshot = designs
                        Task {
                            if !(await WatchfaceStore.saveAsync(snapshot)) {
                                ToastCenter.shared.error(String(localized: "Could not save watchface designs"))
                            }
                        }
                    }, onShare: { share(design) }) {
                        Button { editorDesign = design } label: {
                            HStack(spacing: 14) {
                                FaceThumb(design: design)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(design.name).font(Theme.sans(16, weight: .semibold, relativeTo: .body))
                                        .foregroundStyle(Theme.ink)
                                    Text("^[\(design.widgets.count) complication](inflect: true)")
                                        .font(Theme.sans(13, relativeTo: .footnote)).foregroundStyle(Theme.sub)
                                    if installingDesignID == design.id, let progress = watch.uploadProgress {
                                        installBar(progress)
                                    }
                                }
                                Spacer()
                                if installingDesignID == design.id {
                                    if watch.uploadProgress == nil { ProgressView() }
                                } else if sharingDesignID == design.id {
                                    // Building the .wapp for the export takes
                                    // a moment; the share sheet follows on its
                                    // own once it lands.
                                    ProgressView()
                                } else {
                                    Button("Install") { install(design) }
                                        .font(Theme.sans(14, weight: .semibold, relativeTo: .subheadline))
                                        .foregroundStyle(Theme.accent)
                                        .disabled(isInstalling)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle((PressableRow()))
                        .background(Theme.card)
                    }
                    Hairline(leading: 80)
                }
                Button {
                    editorDesign = WatchfaceDesign(name: "MyFace\(designs.count + 1)")
                } label: {
                    HStack(spacing: 14) {
                        Circle().strokeBorder(Theme.dashedStroke, style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
                            .frame(width: 50, height: 50)
                            .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.accent))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Create a watchface").font(Theme.sans(16, weight: .semibold, relativeTo: .body))
                                .foregroundStyle(Theme.accent)
                            Text("Your own photo and complications")
                                .font(Theme.sans(13, relativeTo: .footnote)).foregroundStyle(Theme.sub)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .contentShape(Rectangle())
                }.buttonStyle(PressableRow())
                Hairline(leading: 16)
                Button {
                    importingFace = true
                } label: {
                    brassRow("square.and.arrow.down", "Import a shared face")
                }.buttonStyle(PressableRow())
            }
            Footer("Designs stay on your phone. Install pushes the 2-bit e-ink render over Bluetooth — larger photos take a few seconds. Swipe a design right to share it — the file carries its background image.")
        }
    }

    // MARK: Bundled

    private var bundledSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Bundled").padding(.top, 26)
            ThemedCard {
                ForEach(Array(BundledFaces.all.enumerated()), id: \.element.id) { i, face in
                    HStack(spacing: 14) {
                        BundledFaceThumb(thumbnail: face.thumbnail)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(face.displayName).font(Theme.sans(16, weight: .semibold, relativeTo: .body))
                                .foregroundStyle(Theme.ink)
                            if let summary = face.displaySummary {
                                Text(summary).font(Theme.sans(12, relativeTo: .caption))
                                    .foregroundStyle(Theme.sub)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if installingBundledID == face.id, let progress = watch.uploadProgress {
                                installBar(progress)
                            }
                        }
                        Spacer()
                        if installingBundledID == face.id {
                            if watch.uploadProgress == nil { ProgressView() }
                        } else {
                            Button("Install") { install(face) }
                                .font(Theme.sans(14, weight: .semibold, relativeTo: .subheadline))
                                .foregroundStyle(Theme.accent)
                                .fixedSize()
                                .disabled(isInstalling)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    if i < BundledFaces.all.count - 1 { Hairline(leading: 80) }
                }
            }
            Footer("Ready-made faces shipped with the app. Install pushes it straight to the watch and makes it active.")
        }
    }

    private func installBar(_ progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accentSoft)
                Capsule().fill(Theme.accent).frame(width: geo.size.width * progress)
            }
        }
        .frame(width: 120, height: 4)
        .padding(.top, 6)
    }

    // MARK: Gallery

    private var gallerySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Gallery").padding(.top, 26)
            ThemedCard {
                ForEach(Array(WatchfaceDesign.gallery.enumerated()), id: \.element.id) { i, preset in
                    Button {
                        var copy = preset
                        copy.id = UUID()
                        editorDesign = copy
                    } label: {
                        HStack(spacing: 14) {
                            FaceThumb(design: preset)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name).font(Theme.sans(16, weight: .semibold, relativeTo: .body))
                                    .foregroundStyle(Theme.ink)
                                Text(preset.widgets.map { WidgetCatalog.title(for: $0.type) }
                                        .joined(separator: ", "))
                                    .font(Theme.sans(13, relativeTo: .footnote)).foregroundStyle(Theme.sub)
                            }
                            Spacer()
                            Chevron()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }.buttonStyle(PressableRow())
                    if i < WatchfaceDesign.gallery.count - 1 { Hairline(leading: 80) }
                }
            }
            Footer("Starting points — tap one to customize it with your own photo, then install.")
        }
    }

    // MARK: Custom widget text

    private var customWidgetSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Custom widget text").padding(.top, 26)
            ThemedCard {
                VStack(spacing: 12) {
                    TextField("Upper text", text: $customUpper)
                        .textFieldStyle(.roundedBorder)
                    TextField("Lower text", text: $customLower)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(16)
            }
            Footer("Changes update the Custom text complication automatically and are restored when this watch reconnects.")
        }
    }

    private func scheduleCustomTextPush() {
        customTextPushTask?.cancel()
        customTextPushTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled,
                  WatchRegistry.activeKindSync().hasApps,
                  watch.connectionState == .ready, watch.isAuthenticated else { return }
            do {
                try await watch.setCustomWidgetText(upper: customUpper, lower: customLower)
            } catch {
                guard watch.connectionState == .ready else { return }
                await MainActor.run { ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }

    // MARK: Small row helpers

    private func brassRow(_ symbol: String, _ title: LocalizedStringResource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
            // Must be allowed to wrap: an HStack hands a Text its *ideal*
            // single-line width, so a title one point too wide for the column
            // (any longer translation does it) pushed the whole screen's
            // scroll content past the viewport — which turns the vertical
            // ScrollView into a freely pannable 2D one.
            Text(title).font(Theme.sans(15, weight: .semibold, relativeTo: .body))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func emptyLine(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(Theme.sans(14, relativeTo: .subheadline)).foregroundStyle(Theme.sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    private func runBusy(_ message: LocalizedStringResource, success: LocalizedStringResource,
                         _ action: @escaping () async throws -> Void) {
        busyText = String(localized: message)
        Task {
            do {
                try await action()
                await MainActor.run {
                    busyText = nil
                    ToastCenter.shared.success(String(localized: success))
                }
            } catch {
                await MainActor.run { busyText = nil; ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }

    /// One gesture, one operation: the right-swipe builds the `.hbface` and
    /// the share sheet appears by itself when it's ready.
    private func share(_ design: WatchfaceDesign) {
        guard sharingDesignID == nil else { return }
        sharingDesignID = design.id
        Task {
            do {
                let url = try await WatchfaceSharing.exportTemporaryFile(for: design)
                await MainActor.run {
                    sharingDesignID = nil
                    exportedFace = ExportedFace(url: url)
                }
            } catch {
                await MainActor.run {
                    sharingDesignID = nil
                    ToastCenter.shared.error(error.localizedDescription)
                }
            }
        }
    }

    private func importFace(from url: URL) {
        let imported: WatchfaceDesign
        do {
            imported = try WatchfaceSharing.importDesign(from: url, existing: designs)
        } catch {
            ToastCenter.shared.error(error.localizedDescription)
            return
        }
        designs.append(imported)
        let snapshot = designs
        Task {
            if await WatchfaceStore.saveAsync(snapshot) {
                ToastCenter.shared.success(
                    String(localized: "\(imported.name) added to your designs"))
            } else {
                ToastCenter.shared.error(String(localized: "Could not save watchface designs"))
            }
        }
    }

    private func install(_ design: WatchfaceDesign) {
        installingDesignID = design.id
        Task {
            do {
                let wapp = try await Task.detached(priority: .utility) {
                    try WappBuilder(design: design).build()
                }.value
                UIApplication.shared.isIdleTimerDisabled = true
                defer { UIApplication.shared.isIdleTimerDisabled = false }
                try await watch.installWatchface(wapp: wapp, name: design.sanitizedName)
                await MainActor.run {
                    installingDesignID = nil
                    ToastCenter.shared.success(
                        String(localized: "\(design.name) installed and activated"))
                }
            } catch {
                await MainActor.run { installingDesignID = nil; ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }

    private func install(_ face: BundledFace) {
        installingBundledID = face.id
        Task {
            do {
                let wapp = try Data(contentsOf: face.url)
                UIApplication.shared.isIdleTimerDisabled = true
                defer { UIApplication.shared.isIdleTimerDisabled = false }
                try await watch.installApp(wapp: wapp)
                await MainActor.run {
                    installingBundledID = nil
                    ToastCenter.shared.success(
                        String(localized: "\(face.displayName) installed and activated"))
                }
            } catch {
                await MainActor.run { installingBundledID = nil; ToastCenter.shared.error(error.localizedDescription) }
            }
        }
    }
}

struct WatchfaceThumbnail: View {
    let design: WatchfaceDesign
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.secondary.opacity(0.4)))
        .task(id: design) {
            let rendered = await Task.detached(priority: .utility) {
                autoreleasepool { WatchfacePreviewRenderer.render(design: design) }
            }.value
            guard !Task.isCancelled else { return }
            image = rendered
        }
    }
}

/// 50pt e-ink face thumbnail rendering a design, with the dark inset ring.
struct FaceThumb: View {
    let design: WatchfaceDesign
    var body: some View {
        WatchfaceThumbnail(design: design)
            .frame(width: 50, height: 50)
            .overlay(Circle().strokeBorder(Color(hex: 0x2A271F), lineWidth: 2))
    }
}

/// 50pt thumbnail for a bundled face's sidecar PNG, falling back to the
/// generic e-ink thumb when none is shipped alongside the .wapp.
struct BundledFaceThumb: View {
    let thumbnail: UIImage?
    var body: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 50)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color(hex: 0x2A271F), lineWidth: 2))
        } else {
            EInkThumb()
        }
    }
}

/// Generic dark e-ink thumbnail for installed faces (no local design to render).
struct EInkThumb: View {
    var body: some View {
        Circle()
            .fill(Color(hex: 0x14130F))
            .frame(width: 50, height: 50)
            .overlay(Circle().strokeBorder(Color(hex: 0x2A271F), lineWidth: 2))
            .overlay(
                Image(systemName: "clock")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Color(hex: 0xE8E4DA)))
    }
}
