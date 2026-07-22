import Foundation

/// Durable evidence for an activity file that passed transport validation but
/// could not be parsed. Keeping both the identity and the raw bytes prevents a
/// five-minute redownload loop while still giving support something concrete
/// to diagnose from a production build.
struct ActivityQuarantineRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { watchID }
    let watchID: UUID
    let handle: UInt16
    let version: UInt8
    let length: Int
    let fingerprint: UInt32
    let failureCategory: String
    let firstFailure: Date
    var lastFailure: Date
    var retryCount: Int
    let rawFilename: String
}

actor ActivityQuarantineStore {
    static let shared = ActivityQuarantineStore()

    private struct Index: Codable {
        var schemaVersion = 1
        var records: [ActivityQuarantineRecord]
    }

    private let directory: URL
    private let indexURL: URL
    private var records: [UUID: ActivityQuarantineRecord]?

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ActivityQuarantine", isDirectory: true)
        self.directory = base
        self.indexURL = base.appendingPathComponent("index.json")
    }

    func record(for watchID: UUID) -> ActivityQuarantineRecord? {
        loadIfNeeded()
        return records?[watchID]
    }

    /// Lookup supplies the concrete handle before a download. Fossil advances
    /// its minor/version when replacing a file, so a changed handle is a new
    /// identity and may be retried automatically.
    func shouldSkipAutomaticDownload(watchID: UUID, handle: UInt16) -> Bool {
        loadIfNeeded()
        return records?[watchID]?.handle == handle
    }

    func noteExplicitRetry(watchID: UUID, handle: UInt16) {
        loadIfNeeded()
        guard var record = records?[watchID], record.handle == handle else { return }
        record.retryCount += 1
        record.lastFailure = Date()
        records?[watchID] = record
        try? persistIndex()
    }

    @discardableResult
    func quarantine(_ data: Data, watchID: UUID, handle: UInt16,
                    failureCategory: String) throws -> ActivityQuarantineRecord {
        loadIfNeeded()
        try prepareDirectory()
        let filename = "activity-\(watchID.uuidString)-\(String(handle, radix: 16)).bin"
        let rawURL = directory.appendingPathComponent(filename)
        try data.write(to: rawURL, options: [.atomic, .completeFileProtection])
        try excludeFromBackup(rawURL)

        let now = Date()
        let previous = records?[watchID]
        let sameIdentity = previous?.handle == handle
        let record = ActivityQuarantineRecord(
            watchID: watchID,
            handle: handle,
            version: UInt8(handle & 0xFF),
            length: data.count,
            fingerprint: Checksums.crc32(data),
            failureCategory: failureCategory,
            firstFailure: sameIdentity ? (previous?.firstFailure ?? now) : now,
            lastFailure: now,
            retryCount: sameIdentity ? (previous?.retryCount ?? 0) : 0,
            rawFilename: filename)
        records?[watchID] = record
        do {
            try persistIndex()
        } catch {
            records?[watchID] = previous
            throw error
        }
        return record
    }

    func exportURL(for watchID: UUID) -> URL? {
        loadIfNeeded()
        guard let filename = records?[watchID]?.rawFilename else { return nil }
        let url = directory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func clear(watchID: UUID) {
        loadIfNeeded()
        guard let old = records?.removeValue(forKey: watchID) else { return }
        do {
            try persistIndex()
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(old.rawFilename))
        } catch {
            records?[watchID] = old
        }
    }

    private func loadIfNeeded() {
        guard records == nil else { return }
        guard let data = try? Data(contentsOf: indexURL) else {
            records = [:]
            return
        }
        do {
            let index = try JSONDecoder().decode(Index.self, from: data)
            records = Dictionary(uniqueKeysWithValues: index.records.map { ($0.watchID, $0) })
        } catch {
            // Preserve a damaged index instead of silently overwriting it.
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let corrupt = directory.appendingPathComponent("index.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: indexURL, to: corrupt)
            records = [:]
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)
    }

    private func persistIndex() throws {
        try prepareDirectory()
        let value = Index(records: Array((records ?? [:]).values)
            .sorted { $0.watchID.uuidString < $1.watchID.uuidString })
        let data = try JSONEncoder().encode(value)
        try data.write(to: indexURL, options: [.atomic, .completeFileProtection])
        // Verify the committed bytes before treating the update as durable.
        _ = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
        try excludeFromBackup(indexURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
