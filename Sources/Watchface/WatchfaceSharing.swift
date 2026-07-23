import Foundation

/// Export/import of `.hbface` packages. Both directions are deliberately
/// file-based: a face leaves the app as a document the user hands to someone
/// through the share sheet, and arrives the same way (Files picker, or opened
/// from Messages/AirDrop via `WatchfaceImportRouter`).
enum WatchfaceSharing {
    static let fileExtension = "hbface"

    /// Builds `design` and writes it as a `.hbface` into the temporary
    /// directory, returning the URL to hand to the share sheet. The `.wapp`
    /// build is the slow part (seconds for a busy photo) and runs off the main
    /// actor, exactly as the install path does.
    static func exportTemporaryFile(for design: WatchfaceDesign) async throws -> URL {
        let wapp = try await Task.detached(priority: .utility) {
            try WappBuilder(design: design).build()
        }.value
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let package = SharedWatchfacePackage(design: design, compiledWapp: wapp,
                                             sourceAppVersion: version)
        let data = try package.encoded()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(design.sanitizedName)
            .appendingPathExtension(fileExtension)
        // A face shared twice would otherwise keep the first export's bytes.
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Reads a `.hbface` and returns the design to append to "My designs",
    /// with a fresh identity so importing never overwrites an existing face.
    /// Follows the same security-scoped/size discipline as `AppsView`'s `.wapp`
    /// importer — the URL comes from outside the sandbox.
    static func importDesign(from url: URL, existing: [WatchfaceDesign]) throws -> WatchfaceDesign {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize, fileSize > 0 else {
            throw SharedWatchfaceError.notAPackage
        }
        guard fileSize <= SharedWatchfacePackage.maxPackageBytes else {
            throw SharedWatchfaceError.tooLarge
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw SharedWatchfaceError.unreadableFile(url.lastPathComponent)
        }

        let package = try SharedWatchfacePackage.decode(data)
        var design = package.design
        design.id = UUID()
        design.name = SharedWatchfacePackage.uniqueName(design.name, existing: existing.map(\.name))
        return design
    }
}
