import Foundation

/// Caches the bytes of every watch app uploaded to any Hybrid HR, keyed by
/// name, so a second watch that doesn't have the app yet can be re-uploaded
/// to from cached bytes instead of needing the source watch (which isn't
/// connected during a switch). Global like `ButtonStore`/`MenuStore` — the
/// button/menu config that references these apps is shared across watches
/// too. Watchfaces are never cached here; only apps referenced by a button
/// assignment or menu `openApp` item need to survive a watch switch.
///
/// Follows `WatchfaceStore`'s plain-JSON-in-Documents shape, with the
/// file-protection / backup-exclusion hardening from `FitnessStore` so a
/// background reconnect-init can still read cached bytes while the phone is
/// locked.
final class UploadedAppStore {
    static let shared = UploadedAppStore()

    struct Record: Codable {
        var name: String
        var identifier: String?
        var fileName: String
    }

    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private let lock = NSLock()

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("uploaded_apps")
        try? FileManager.default.createDirectory(at: self.directory,
                                                  withIntermediateDirectories: true)
    }

    private func loadIndex() -> [Record] {
        guard let data = try? Data(contentsOf: indexURL),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return records
    }

    /// Encodes and writes `data` to `url`, hardened like `FitnessStore`'s
    /// archive writes: prefer full file protection, fall back to the
    /// until-first-unlock class rather than fail outright, and exclude from
    /// backups either way.
    private func write(_ data: Data, to url: URL) {
        let attempts: [Data.WritingOptions] = [[.atomic, .completeFileProtection],
                                               [.atomic, .completeFileProtectionUntilFirstUserAuthentication]]
        for options in attempts {
            do {
                try data.write(to: url, options: options)
                var excluded = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? excluded.setResourceValues(values)
                return
            } catch {
                NSLog("UploadedAppStore: write failed (\(options)): \(error)")
            }
        }
    }

    private func saveIndex(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        write(data, to: indexURL)
    }

    /// Caches `wapp`'s bytes under `name`, overwriting any previous blob for
    /// that name. Never call this for watchfaces — only apps need to survive
    /// a watch switch via the global button/menu config.
    func remember(name: String, wapp: Data) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadIndex()
        let fileName: String
        if let existing = records.first(where: { $0.name == name }) {
            fileName = existing.fileName
        } else {
            fileName = "\(UUID().uuidString).wapp"
        }
        write(wapp, to: directory.appendingPathComponent(fileName))
        let identifier = WappReader.identifier(fromWapp: wapp)
        records.removeAll { $0.name == name }
        records.append(Record(name: name, identifier: identifier, fileName: fileName))
        saveIndex(records)
    }

    /// The cached bytes for `name`, or nil if nothing has been uploaded under
    /// that name yet.
    func data(forName name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = loadIndex().first(where: { $0.name == name }) else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(record.fileName))
    }

    /// The names of every cached app.
    var names: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(loadIndex().map(\.name))
    }

    /// Removes the cached record and blob for `name`. Not called automatically
    /// on a watch-side delete — the global button/menu config may still
    /// reference the app for another watch. A future "manage cached apps" UI
    /// would call this.
    func forget(name: String) {
        lock.lock()
        defer { lock.unlock() }
        var records = loadIndex()
        guard let record = records.first(where: { $0.name == name }) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.fileName))
        records.removeAll { $0.name == name }
        saveIndex(records)
    }
}
