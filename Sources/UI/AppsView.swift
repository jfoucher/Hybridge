import SwiftUI
import UniformTypeIdentifiers

/// Manage watch apps: list installed apps/watchfaces, delete them, import an
/// arbitrary .wapp, and install the bundled Home Assistant app.
struct AppsView: View {
    @EnvironmentObject var watch: WatchManager
    @State private var busyText: String?
    @State private var importing = false
    @State private var pendingFirmware: Data?
    @State private var downloadedApp: (name: String, url: URL)?

    private var homeAssistantInstalled: Bool {
        watch.installedApps.contains { $0.name == "homeAssistantApp" }
    }

    var body: some View {
        List {
            Section("On the watch") {
                if watch.installedApps.isEmpty {
                    Text("No apps listed yet.").foregroundStyle(.secondary)
                }
                ForEach(watch.installedApps) { app in
                    HStack {
                        Image(systemName: app.isWatchface ? "clock" : "square.grid.2x2")
                            .foregroundStyle(.secondary)
                        Text(app.name)
                        Spacer()
                        if app.isOutdated == true {
                            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                                .foregroundStyle(.orange)
                                .help("A newer version exists")
                        }
                        Text("v\(app.version)").font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            run("Removing \(app.name)…", success: "\(app.name) removed") {
                                try await watch.deleteApp(app)
                            }
                        } label: { Label("Delete", systemImage: "trash") }
                        Button {
                            downloadApp(app)
                        } label: { Label("Download", systemImage: "square.and.arrow.down") }
                        .tint(.green)
                        if !app.isWatchface {
                            Button {
                                run("Starting \(app.name)…", success: "\(app.name) started") {
                                    try await watch.startAppOnWatch(app.name)
                                }
                            } label: { Label("Launch", systemImage: "play") }
                            .tint(.blue)
                        }
                    }
                }
                Button {
                    run("Refreshing…", success: "List refreshed") {
                        try await watch.refreshInstalledApps()
                    }
                } label: { Label("Refresh list", systemImage: "arrow.clockwise") }
            }

            Section {
#if DEBUG
                Button {
                    importing = true
                } label: { Label("Import .wapp or firmware…", systemImage: "square.and.arrow.down") }
#endif

                Button {
                    run("Installing Home Assistant…", success: "Home Assistant app installed") {
                        try await watch.installHomeAssistantApp()
                    }
                } label: {
                    Label(homeAssistantInstalled ? String(localized: "Home Assistant app installed")
                                                 : String(localized: "Install Home Assistant app"),
                          systemImage: "house")
                }
                .disabled(homeAssistantInstalled || busyText != nil)
            } header: {
                Text("Install")
            } footer: {
                Text("Installs the bundled, reviewed Home Assistant watch app. Arbitrary app and firmware import is available only in development builds because watch apps can request privileged phone integrations and an incompatible firmware image can permanently damage a watch.")
            }

            if let downloadedApp {
                Section("Last download") {
                    ShareLink(item: downloadedApp.url) {
                        Label("Share \(downloadedApp.name).wapp", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if let busyText {
                Section {
                    HStack {
                        if let progress = watch.uploadProgress {
                            ProgressView(value: progress).progressViewStyle(.linear)
                        } else {
                            ProgressView()
                        }
                        Text(busyText)
                    }
                }
            }
        }
        .navigationTitle("Apps")
        .themedList()
#if DEBUG
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "wapp") ?? .data, .data]) { result in
            handleImport(result)
        }
        .confirmationDialog("Flash firmware?", isPresented: firmwareDialogShown,
                            titleVisibility: .visible) {
            Button("Flash firmware \(pendingFirmware.flatMap(FirmwareReader.version) ?? "")",
                   role: .destructive) {
                flashPendingFirmware()
            }
        } message: {
            Text("Keep the app open and the watch nearby for the whole transfer (several minutes). The watch reboots when done. A failed flash can require recovery — only use firmware images for the Hybrid HR.")
        }
#endif
    }

#if DEBUG
    private var firmwareDialogShown: Binding<Bool> {
        Binding(get: { pendingFirmware != nil },
                set: { if !$0 { pendingFirmware = nil } })
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        // Files picked outside the sandbox need a security-scoped access grant.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let maxImportSize = max(FirmwareReader.maxSize, WappReader.maxContainerSize)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0, fileSize <= maxImportSize else {
            ToastCenter.shared.error(String(localized: "The selected file is empty, too large, or not a regular file."))
            return
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            ToastCenter.shared.error(String(localized: "Could not read \(url.lastPathComponent)"))
            return
        }
        if FirmwareReader.isFirmware(data) {
            pendingFirmware = data
            return
        }
        run("Installing \(url.lastPathComponent)…", success: "\(url.lastPathComponent) installed") {
            try await watch.installApp(wapp: data)
        }
    }

    private func flashPendingFirmware() {
        guard let firmware = pendingFirmware else { return }
        pendingFirmware = nil
        UIApplication.shared.isIdleTimerDisabled = true
        run("Flashing firmware — keep the app open…",
            success: "Firmware transferred; the watch is rebooting") {
            defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }
            try await watch.installFirmware(firmware)
        }
    }
#endif

    private func downloadApp(_ app: InstalledApp) {
        run("Downloading \(app.name)…", success: "\(app.name) ready to share") {
            let data = try await watch.downloadApp(app)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(app.name).wapp")
            try data.write(to: url)
            await MainActor.run { downloadedApp = (app.name, url) }
        }
    }

    private func run(_ message: LocalizedStringResource, success: LocalizedStringResource,
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
}
