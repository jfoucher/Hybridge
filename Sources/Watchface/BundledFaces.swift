import UIKit

/// A ready-made watchface `.wapp` shipped in the app bundle (see
/// `Resources/bundled_faces/README.md`), installed with one tap from
/// `WatchfacesView` — no Files picker, no editor round-trip.
struct BundledFace: Identifiable {
    let url: URL
    let name: String
    /// One-line blurb from the wapp's displayName section, nil for faces
    /// that don't carry one.
    let summary: String?
    let thumbnail: UIImage?
    var id: String { url.lastPathComponent }
    var displayName: String { BundledFaces.localizedName(name) }
    var displaySummary: String? { summary.map(BundledFaces.localizedSummary) }
}

/// Discovers the bundled faces once at process start. Files that don't
/// parse as a watchface are silently skipped — this folder is developer-
/// provisioned, not user-facing error surface.
enum BundledFaces {
    static let all: [BundledFace] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "wapp", subdirectory: "bundled_faces") ?? []
        return urls.compactMap { url -> BundledFace? in
            guard let data = try? Data(contentsOf: url),
                  let meta = WappReader.metadata(fromWapp: data), meta.isWatchface
            else { return nil }
            let thumbURL = url.deletingPathExtension().appendingPathExtension("png")
            let thumbnail = UIImage(contentsOfFile: thumbURL.path)
            return BundledFace(url: url, name: meta.name,
                               summary: WappReader.description(fromWapp: data),
                               thumbnail: thumbnail)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }()

    /// The metadata lives inside precompiled .wapp files, where the compiler
    /// cannot discover it for localization. Keep this switch in source so all
    /// bundled-face copy is exported to the String Catalog.
    static func localizedName(_ name: String) -> String {
        switch name {
        case "Almanac": String(localized: "Almanac", comment: "Bundled watchface name")
        case "Arcade": String(localized: "Arcade", comment: "Bundled watchface name")
        case "Daily": String(localized: "Daily", comment: "Bundled watchface name")
        case "Fluted": String(localized: "Fluted", comment: "Bundled watchface name")
        case "Gazette": String(localized: "Gazette", comment: "Bundled watchface name")
        case "Grande II": String(localized: "Grande II", comment: "Bundled watchface name")
        case "Horizon": String(localized: "Horizon", comment: "Bundled watchface name")
        case "Meridian": String(localized: "Meridian", comment: "Bundled watchface name")
        case "Meteo": String(localized: "Meteo", comment: "Bundled watchface name")
        case "Piet": String(localized: "Piet", comment: "Bundled watchface name")
        case "Pulse": String(localized: "Pulse", comment: "Bundled watchface name")
        case "Reserve": String(localized: "Reserve", comment: "Bundled watchface name")
        case "Retro": String(localized: "Retro", comment: "Bundled watchface name")
        case "Rings": String(localized: "Rings", comment: "Bundled watchface name")
        case "Sector": String(localized: "Sector", comment: "Bundled watchface name")
        case "Todo": String(localized: "Todo", comment: "Bundled watchface name")
        default: name
        }
    }

    static func localizedSummary(_ summary: String) -> String {
        switch summary {
        case "This week at a glance: Monday-to-Sunday dates with today boxed, ISO week, day of the year and a year gauge.":
            String(localized: "This week at a glance: Monday-to-Sunday dates with today boxed, ISO week, day of the year and a year gauge.")
        case "Space-invaders scoreboard: steps as SCORE, your goal as HI, battery beside the heart.":
            String(localized: "Space-invaders scoreboard: steps as SCORE, your goal as HI, battery beside the heart.")
        case "Typographic board: weekday, date and month above steps, kcal, active minutes and temperature.":
            String(localized: "Typographic board: weekday, date and month above steps, kcal, active minutes and temperature.")
        case "Classic dress watch: fluted bezel, baton indices and a cyclops date lens at 3.":
            String(localized: "Classic dress watch: fluted bezel, baton indices and a cyclops date lens at 3.")
        case "White broadsheet front page: dateline, steps as the headline, weather and battery insets.":
            String(localized: "White broadsheet front page: dateline, steps as the headline, weather and battery insets.")
        case "Thirteen complications sized for reading: 24h dial with moonphase aperture, weather trio, reserve rim.":
            String(localized: "Thirteen complications sized for reading: 24h dial with moonphase aperture, weather trio, reserve rim.")
        case "Sun clock: the orb rides a 24h ring, sunrise/sunset times and how much daylight is left.":
            String(localized: "Sun clock: the orb rides a 24h ring, sunrise/sunset times and how much daylight is left.")
        case "World timer: local time and date over three configurable zones, each with its own day/night mark.":
            String(localized: "World timer: local time and date over three configurable zones, each with its own day/night mark.")
        case "Weather at a glance: condition icon, temperature, rain and UV, steps on a battery rim.":
            String(localized: "Weather at a glance: condition icon, temperature, rain and UV, steps on a battery rim.")
        case "Mondrian composition: date, steps and kcal in colored cells, battery as a filling bar.":
            String(localized: "Mondrian composition: date, steps and kcal in colored cells, battery as a filling bar.")
        case "Live heart rate over an ECG trace, with weekday, date, steps and calories.":
            String(localized: "Live heart rate over an ECG trace, with weekday, date, steps and calories.")
        case "Roman-numeral complication dial with a computed moonphase and a power-reserve battery fan.":
            String(localized: "Roman-numeral complication dial with a computed moonphase and a power-reserve battery fan.")
        case "Twin retrograde fans: steps and battery needles sweeping 120-degree scales, date window.":
            String(localized: "Twin retrograde fans: steps and battery needles sweeping 120-degree scales, date window.")
        case "Three concentric goal rings - steps, battery and active minutes - values stacked in the center.":
            String(localized: "Three concentric goal rings - steps, battery and active minutes - values stacked in the center.")
        case "Mechanical dial with BPM and calorie sub-eyes, a steps goal ring and a date window.":
            String(localized: "Mechanical dial with BPM and calorie sub-eyes, a steps goal ring and a date window.")
        case "White notepad checklist whose boxes tick themselves as steps, kcal, active and charge goals are met.":
            String(localized: "White notepad checklist whose boxes tick themselves as steps, kcal, active and charge goals are met.")
        default: summary
        }
    }

    /// The bundled face whose name matches the active-watchface name (both come
    /// from `WappReader.metadata`), or nil. Used to preview the active face
    /// locally when the live BLE download hasn't produced an image yet.
    static func matching(name: String?) -> BundledFace? {
        guard let name else { return nil }
        return all.first { $0.name == name }
    }
}
