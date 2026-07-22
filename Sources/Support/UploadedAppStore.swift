import Foundation

/// Caches the bytes of every watch app uploaded to any Hybrid HR, keyed by
/// name, so a second watch that doesn't have the app yet can be re-uploaded
/// to from cached bytes instead of needing the source watch (which isn't
/// connected during a switch). Global like `ButtonStore` — the button config
/// that references these apps is shared across watches too. Watchfaces are
/// never cached here; only apps referenced by a button assignment need to
/// survive a watch switch.
///
/// Follows `WatchfaceStore`'s plain-JSON-in-Documents shape, with the
/// file-protection / backup-exclusion hardening from `FitnessStore` so a
/// background reconnect-init can still read cached bytes while the phone is
/// locked.
final class UploadedAppStore: @unchecked Sendable {
    static let shared = UploadedAppStore()

    struct Record: Codable {
        var name: String
        var identifier: String?
        var fileName: String
    }

    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var previousIndexURL: URL { directory.appendingPathComponent("index.previous-valid.json") }
    private let lock = NSLock()

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("uploaded_apps")
        try? FileManager.default.createDirectory(at: self.directory,
                                                  withIntermediateDirectories: true)
    }

    private func loadIndex() -> [Record] {
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                return try JSONDecoder().decode([Record].self, from: Data(contentsOf: indexURL))
            } catch {
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let quarantine = directory.appendingPathComponent("index.corrupt-\(stamp).json")
                try? FileManager.default.moveItem(at: indexURL, to: quarantine)
                NSLog("UploadedAppStore: preserved unreadable index as \(quarantine.lastPathComponent): \(error)")
            }
        }
        do {
            return try JSONDecoder().decode([Record].self,
                                            from: Data(contentsOf: previousIndexURL))
        } catch {
            if FileManager.default.fileExists(atPath: previousIndexURL.path) {
                NSLog("UploadedAppStore: previous valid index could not be recovered: \(error)")
            }
            return []
        }
    }

    /// Encodes and writes `data` to `url`, hardened like `FitnessStore`'s
    /// archive writes: prefer full file protection, fall back to the
    /// until-first-unlock class rather than fail outright, and exclude from
    /// backups either way.
    private func write(_ data: Data, to url: URL) -> Bool {
        let attempts: [Data.WritingOptions] = [[.atomic, .completeFileProtection],
                                               [.atomic, .completeFileProtectionUntilFirstUserAuthentication]]
        for options in attempts {
            do {
                try data.write(to: url, options: options)
                var excluded = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? excluded.setResourceValues(values)
                guard (try? Data(contentsOf: url)) == data else { return false }
                return true
            } catch {
                NSLog("UploadedAppStore: write failed (\(options)): \(error)")
            }
        }
        return false
    }

    private func saveIndex(_ records: [Record]) -> Bool {
        guard let data = try? JSONEncoder().encode(records), write(data, to: indexURL),
              let verified = try? JSONDecoder().decode(
                [Record].self, from: Data(contentsOf: indexURL)),
              verified.map(\.fileName) == records.map(\.fileName)
        else { return false }
        if !write(data, to: previousIndexURL) {
            NSLog("UploadedAppStore: committed index but could not refresh recovery copy")
        }
        return true
    }

    /// Caches `wapp`'s bytes under `name`, overwriting any previous blob for
    /// that name. Never call this for watchfaces — only apps need to survive
    /// a watch switch via the global button/menu config.
    @discardableResult
    func remember(name: String, wapp: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var records = loadIndex()
        let old = records.first(where: { $0.name == name })
        // Always stage under a fresh name. Overwriting the old blob before the
        // index commit would make an index failure point at changed bytes.
        let fileName = "\(UUID().uuidString).wapp"
        let stagedURL = directory.appendingPathComponent(fileName)
        guard write(wapp, to: stagedURL) else { return false }
        let identifier = WappReader.identifier(fromWapp: wapp)
        records.removeAll { $0.name == name }
        records.append(Record(name: name, identifier: identifier, fileName: fileName))
        guard saveIndex(records) else {
            try? FileManager.default.removeItem(at: stagedURL)
            return false
        }
        if let old, old.fileName != fileName {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(old.fileName))
        }
        return true
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
    @discardableResult
    func forget(name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var records = loadIndex()
        guard let record = records.first(where: { $0.name == name }) else { return true }
        records.removeAll { $0.name == name }
        guard saveIndex(records) else { return false }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.fileName))
        return true
    }
}
