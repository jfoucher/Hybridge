# Bundled watchfaces

The faces here are build products of `Faces/` — `Faces/build.py` writes each
`<identifier>.wapp` and its `<identifier>.png` preview into this directory, so
edit a face there and rebuild rather than editing anything here. Foreign
`.wapp` files may also be dropped in by hand.

They ship in the app's "Bundled" section
(`Sources/UI/WatchfacesView.swift`), installed with one tap via
`WatchManager.installApp(wapp:)`.

- Each face is a `<name>.wapp`. Files that fail to parse as a watchface
  (`WappReader.metadata` returns nil, or `isWatchface == false`) are
  silently skipped by `BundledFaces.all` — this folder is developer-
  provisioned, not user-facing error surface.
- An optional sidecar `<name>.png` (same basename) is used as the row
  thumbnail; without one the UI falls back to the generic `EInkThumb`.
- The row subtitle is the optional `description` file inside the wapp's
  displayName section, read by `WappReader.description(fromWapp:)`. Our
  own faces get it from the `description` key in each face's `app.json`
  (see `Faces/build.py`); foreign faces have none and simply
  show no subtitle. `BundledFacesTests` asserts every face here carries
  one.
- Record provenance/licensing per file before adding it. This project is
  MIT-licensed, but a `.wapp` downloaded off a watch is Fossil's own compiled
  asset (JerryScript bytecode + images), not something we authored —
  don't assume it's fine to redistribute just because it sits in this
  repo. Note where each face came from and whether it's actually meant
  to ship.
