# Localization

Hybridge uses Xcode String Catalogs with English as the development language.

- `Resources/Localizable.xcstrings` contains app, widget, App Intent, local-notification, error, and phone-to-watch copy.
- `Resources/InfoPlist.xcstrings` contains the system privacy permission descriptions.
- Both the app and widget targets compile the shared `Localizable.xcstrings` file. The app target also compiles `InfoPlist.xcstrings`.

## Adding a language

Open `Localizable.xcstrings` and `InfoPlist.xcstrings` in Xcode, use **Editor → Add Localization**, and translate every entry for the new language. String Catalog variations should be used where a language needs plural, grammatical, or device-specific forms.

Xcode can export and import XLIFF packages from **Product → Export Localizations** and **Product → Import Localizations**. Test the result with the scheme's **Application Language** setting, including the built-in pseudolanguages and a right-to-left language.

After changing source copy, build the project with `scripts/xbuild.sh build`. `SWIFT_EMIT_LOC_STRINGS` is enabled for both shipping targets, so Xcode discovers SwiftUI, `LocalizedStringResource`, `String(localized:)`, widget, and App Intent strings. Open the catalog in Xcode to review and sync newly discovered entries before committing.

## Code conventions

- Use string literals directly in standard SwiftUI APIs such as `Text`, `Button`, `Label`, `Section`, and `navigationTitle`.
- Use `LocalizedStringResource` for reusable view helpers and resolve it with `String(localized:)` only at APIs that require `String`.
- Use `String(localized:)` for toasts, notification content, errors, and text sent to the watch.
- Keep user content, device names, app names, bundle identifiers, protocol keys, filenames, SF Symbol names, and diagnostic log messages verbatim.
- Keep interpolation inside the localized resource so translators can reorder values. Do not build sentences by concatenating translated fragments.
- Prefer locale-aware `FormatStyle`, `DateFormatter`, `RelativeDateTimeFormatter`, and `ListFormatter` APIs over fixed date, number, or list formats.

Bundled `.wapp` metadata is precompiled and cannot be discovered automatically. Its app-facing names and summaries are mirrored in `BundledFaces.swift`; update that localization switch whenever bundled face metadata changes.
