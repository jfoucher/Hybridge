import Foundation
import UniformTypeIdentifiers

/// The `.hbface` export/import format — one JSON document holding a compiled
/// `.wapp` plus the editable `WatchfaceDesign` it was built from, traded
/// between Hybridge users over Files/AirDrop/Messages.
///
/// The design is what makes a shared face *editable*: a `.wapp` alone is
/// install-only, because the font family, size, rotation and shade baked into
/// its glyph images are unrecoverable from the container and the background
/// survives only as a 240×240 2-bit render (see `WappReader.textLayers`).
/// `WatchfaceDesign` is already self-contained — `backgroundPNG` is embedded
/// PNG bytes, not a path — so it travels intact.
///
/// The compiled `.wapp` rides along as an integrity gate: it proves the design
/// actually built on the sender's device. It is validated on import and then
/// discarded — installing rebuilds locally, so the *recipient's* locale and
/// fonts apply (weekday and weather-condition labels are baked per-locale, see
/// `WatchfaceValueSource.weekdayNames`). Never hash or diff these bytes to
/// compare two copies of a face: `WappBuilder` is not byte-deterministic
/// across devices (unsorted JSON keys, locale-dependent glyph atlases).
struct SharedWatchfacePackage: Codable, Equatable {
    static let currentFormatVersion = 1
    /// Ceiling on a `.hbface` read from disk. A design carries a 480×480 PNG
    /// (≤2 MB, `BoundedImageProcessor`) plus a `.wapp` (≤4 MB,
    /// `WappReader.maxContainerSize`); base64 inflates both by a third.
    static let maxPackageBytes = 8 * 1024 * 1024

    var formatVersion: Int = currentFormatVersion
    var design: WatchfaceDesign
    var compiledWapp: Data
    /// Marketing version of the app that exported this, for diagnostics. Nil
    /// for packages written before this field existed.
    var sourceAppVersion: String?

    init(design: WatchfaceDesign, compiledWapp: Data, sourceAppVersion: String?) {
        self.design = design
        self.compiledWapp = compiledWapp
        self.sourceAppVersion = sourceAppVersion
    }

    /// `formatVersion` is lenient so a package written by a build that
    /// predates the field still loads; `design` and `compiledWapp` are hard
    /// decodes, so anything that isn't a package throws rather than yielding
    /// an empty face.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion)
            ?? Self.currentFormatVersion
        design = try container.decode(WatchfaceDesign.self, forKey: .design)
        compiledWapp = try container.decode(Data.self, forKey: .compiledWapp)
        sourceAppVersion = try container.decodeIfPresent(String.self, forKey: .sourceAppVersion)
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// The validating decode used by every import path. Plain
    /// `JSONDecoder().decode` gives the format back verbatim; this adds the
    /// checks that make foreign bytes safe to act on.
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw SharedWatchfaceError.notAPackage }
        guard data.count <= maxPackageBytes else { throw SharedWatchfaceError.tooLarge }

        let package: Self
        do {
            package = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw SharedWatchfaceError.notAPackage
        }
        guard package.formatVersion <= currentFormatVersion else {
            throw SharedWatchfaceError.newerFormat
        }
        // The same gate BundledFaces applies to shipped .wapp files.
        guard WappReader.isValidContainer(package.compiledWapp),
              WappReader.metadata(fromWapp: package.compiledWapp)?.isWatchface == true else {
            throw SharedWatchfaceError.notAWatchface
        }
        return package
    }

    /// Longest name an imported face may keep. `sanitizedName` already strips
    /// the name down for the watch; this only keeps the phone-side list sane.
    static let maxNameLength = 40

    /// A display name that doesn't collide with `existing`, trimmed and
    /// length-capped. Imports never overwrite a design the user already has,
    /// so re-importing the same file twice yields "Aurora" and "Aurora 2".
    static func uniqueName(_ name: String, existing: [String]) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = String(localized: "Shared face") }
        if base.count > maxNameLength { base = String(base.prefix(maxNameLength)) }
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }
}

enum SharedWatchfaceError: LocalizedError, Equatable {
    case notAPackage
    case tooLarge
    case newerFormat
    case notAWatchface
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .notAPackage:
            return String(localized: "This isn't a Hybridge watchface file.")
        case .tooLarge:
            return String(localized: "This watchface file is too large to open.")
        case .newerFormat:
            return String(localized: "This watchface was shared from a newer version of Hybridge — update the app to open it.")
        case .notAWatchface:
            return String(localized: "This watchface file is damaged and can't be opened.")
        case .unreadableFile(let name):
            return String(localized: "Could not read \(name)")
        }
    }
}

extension UTType {
    /// Declared in `project.yml` under `UTExportedTypeDeclarations` — keep the
    /// identifier and the `hbface` extension in sync with it.
    static let hybridgeWatchface = UTType(exportedAs: "eu.sixpixels.hybridge.watchface")
}
