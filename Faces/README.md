# Bundled watch faces

Watchfaces for the Fossil/Skagen Hybrid HR, designed to ship with
the unofficial iOS companion app.  They are *inspired by* the official
Fossil faces (Orbit, Status, Meter, Mechanical, Activity, Dashboard)
but contain no code or assets from them — every image is drawn from
scratch with PIL (`gen_assets.py`) and every layout and app.js is
written fresh against the layout-engine behavior documented in
`FACE-DEVELOPMENT.md` next to this file.

They all tell time with the physical hands only (no on-screen hands).

| Face    | .wapp              | Shows |
|---------|--------------------|-------|
| Sector  | `sectorFace.wapp`  | Mechanical-style dial: BPM + KCAL sub-eyes, steps sub-dial with goal ring, date window |
| Meteo   | `meteoFace.wapp`   | Weather: condition icon, temperature, rain %, UV, steps, battery rim ring |
| Rings   | `ringsFace.wapp`   | Three concentric goal rings: steps / battery / active minutes, values stacked center |
| Pulse   | `pulseFace.wapp`   | Big live heart rate over an ECG trace, weekday+date, steps, calories |
| Daily   | `dailyFace.wapp`   | Typographic board: weekday / date / month + steps, kcal, active min, temperature |
| Fluted  | `flutedFace.wapp`  | Classic dress watch: fluted bezel, baton indices, cyclops date lens at 3 |
| Reserve | `reserveFace.wapp` | Complication dial: Roman numerals, computed moonphase at 12, battery as a power-reserve fan, date window |
| TTY     | `ttyFace.wapp`     | Terminal: scanlines + prompt lines for date, steps, kcal, BPM, battery |
| Radar   | `radarFace.wapp`   | Range rings and a sweep hand that tracks the minute (runtime-rotated SVG), steps/BPM HUD |
| Retro   | `retroFace.wapp`   | Twin retrograde fan gauges: steps and battery needles over 120° scales, date window |
| Gnomon  | `gnomonFace.wapp`  | Sundial: 24-hour shadow bar (noon up) over a stone dial, date in Roman numerals |
| Iris    | `irisFace.wapp`    | A giant eye — the hands hub hides in the pupil, a glint orbits to the minute-hand angle |
| Piet    | `pietFace.wapp`    | Mondrian composition: date/steps/kcal in cells, masked-solid battery bar |
| Glass   | `glassFace.wapp`   | Hourglass of the day: sand drains top to bottom as the day passes (masked solids) |
| Arcade  | `arcadeFace.wapp`  | Space-invaders scoreboard: steps = SCORE, goal = HI, battery by the heart |
| Gazette | `gazetteFace.wapp` | White broadsheet front page: dateline, steps as the headline, weather + battery inset boxes |
| Schema  | `schemaFace.wapp`  | White engineering drawing of the watch; date/steps/battery in the title block, hub = center mark |
| Transit | `transitFace.wapp` | White metro map: four lines from the hub interchange to steps/kcal/BPM/battery terminals |
| Calc    | `calcFace.wapp`    | White pocket calculator: steps on the LCD, kcal in memory, hub = the OFF button |
| Todo    | `todoFace.wapp`    | White notepad checklist whose checkboxes tick as goals are met (steps/kcal/active/charge) |
| Grande  | `grandeFace.wapp`  | The grand complication: eight analog sub-dials (moonphase, weekday, date, HR, 24h, active, steps, month) + kcal and reserve rim gauges — no digits anywhere |
| Grande II | `grande2Face.wapp` | Thirteen complications, sized for reading: calendar dial with moonphase aperture and coaxial date+weekday dots, steps+active and HR dials, TEMP/UV mini-dials, month fan, kcal/rain/reserve rim gauges |
| Horizon | `horizonFace.wapp` | Sun clock: the orb rides a 24h ring (daylight over the top, night under the bottom), sunrise/sunset times, daylight left |
| Meridian | `meridianFace.wapp` | World timer: local time + date + UTC offset over three configurable zones, each with a +1/-1 date mark and a day/night token |
| Almanac | `almanacFace.wapp` | Mon-to-Sun date strip with today boxed, ISO week number, day of the year, and a rim gauge for the year (ticked per month) |
| Split   | `splitFace.wapp`   | Hard diagonal duotone: weekday on the dark half, date huge on the light half, steps on the seam |
| Stack   | `stackFace.wapp`   | White: a bold bar chart — steps / active minutes / battery as heavy bars over grey tracks |
| Type    | `typeFace.wapp`    | White: the weekday set huge over a heavy rule, a big date, and a steps footer |
| Rayon   | `rayonFace.wapp`   | Sunburst dial: fine rays radiate from the centre under applied baton indices; date below, steps above |
| Deco    | `decoFace.wapp`    | Art Deco: a crown sunburst, fine rules and stepped motifs frame a lozenge date; steps and battery in the wings |
| Aria    | `ariaFace.wapp`    | White: two delicate hairline arcs trace steps and battery around the dial, with the readings set fine |
| Ivory   | `ivoryFace.wapp`   | White: a porcelain dial with a railroad track and fine serif numerals; date framed at six, steps at twelve |
| Seigaiha| `seigaihaFace.wapp`| White: the Japanese seigaiha wave-scallop pattern, with the date and steps in fine applied cartouches |

## Data sources

* On-watch: `common.step_count`, `.calories`, `.battery_soc`,
  `.active_minutes`, `.hr_bpm` (shows `--` until the HRM delivers),
  `.year/.month/.date` (weekday via Sakamoto's method — no `Date` in
  jerry es5.1).
* Weather (Meteo, Daily): `req_data('"weatherInfo":{}')` round-trip;
  the companion's WeatherProvider answers with
  `{alive, unit, temp, cond_id, rain, uv}`.  `cond_id` uses the
  Gadgetbridge icon table: 0/1 clear day/night, 2 cloudy, 3/4 partly
  day/night, 5 rain, 6/7 snow, 8 storm, 10 wind.  Slots show `--`
  until an answer arrives (and again once `alive` expires).
* Sun times (Horizon): computed on-watch from `config.position`
  (defaults to Paris; the watch has no GPS).  Push a location the same
  way the moonphase app does:
  `horizonFace._.config.position = {"lat": 48.85, "lon": 2.35}`.
  The compact solar-position routine agrees with that app's SunCalc
  port to the minute, and reports `MIDNIGHT SUN` / `POLAR NIGHT`
  inside the polar circles instead of inventing a sunrise.
* Time zones (Meridian): `config.zones` — a list of
  `{"name": "NYC", "offset": <minutes from UTC>}`, up to three, e.g.
  `meridianFace._.config.zones = [{"name":"NYC","offset":-240}]`.
  Offsets are fixed, so a zone crossing into summer time needs a new
  push (the watch has no tz database).

## Toolchain

Everything needed to build a face is vendored under `vendor/` as git
submodules and built by `make deps` (once, ~5 min):

* `vendor/jerryscript` — **JerryScript 2.1.0**, the engine the watch
  runs. `make deps` builds it twice: the stock build
  (`build/bin/jerry-snapshot`, error messages off as on the watch)
  compiles `app.js` into the snapshot that ships, and an
  error-messages-on build (`build-errmsg/bin/jerry`) is what `test.py`
  and `simulate.py` *run* app.js under, because a stock ReferenceError
  prints an empty message. **Newer JerryScript releases produce
  snapshots the firmware rejects** — the submodule is pinned at the
  `v2.1.0` tag, don't move it.
* `vendor/Fossil-HR-SDK` — `tools/image_compress.py` (PNG → the watch's
  RLE format) and `tools/pack.py` (the five-section `.wapp` container).

```
git submodule update --init --recursive   # or just `make deps`
make deps                                 # build jerry + pip install crc32c, pillow
```

`layout_engine.py` resolves both from `vendor/`; `JERRY_DIR` and
`FOSSIL_SDK_TOOLS` in the environment override that if you keep a
toolchain elsewhere.

Two concessions to building 2020 code with a current toolchain, both in
the `Makefile` and both applied by `make deps`:

* `make patch-jerry` rewrites `cmake_minimum_required` from 2.8.12 to
  3.5 in the submodule's twelve `CMakeLists.txt` — CMake 4 dropped
  compatibility below 3.5 and refuses to configure otherwise. The edit
  is idempotent and re-applies after a `git submodule update`, but it
  does leave the submodule's worktree dirty; that is expected.
* the builds pass `--compile-flag=-w`. JerryScript 2.1.0 compiles with
  `-Werror` plus `-Werror=all`/`-Werror=extra`, and clang has since
  added diagnostics it trips (`-Wenum-enum-conversion` in
  `ecma-builtins.c`). A bare `-Wno-error` does not undo the
  `-Werror=<group>` forms, hence `-w`.

Neither changes what comes out: a face built with the freshly compiled
toolchain is byte-identical to one built before these patches.

## Build & test

```
make          # test, build every .wapp into this directory, then the gallery
make test     # harness only
make build    # .wapp files only
python3 build.py sector   # one face
python3 simulate.py sector --scenario day
```

Each build also copies `<identifier>.wapp` and its preview as
`<identifier>.png` into the companion app's `Resources/bundled_faces/`
(all but the `NOT_BUNDLED` set). The `.wapp` files left in this
directory are build products.

The `description` string in a face's `app.json` is packed into the
`.wapp` as a `description` file in the display_name section (next to
`display_name` and `theme_class`; the watch looks section files up by
name, so the extra entry is inert on-device). The companion app reads
it back with `WappReader.description(fromWapp:)` and shows it as the
subtitle in its Bundled list — so the blurb travels with the file,
including faces imported by hand.

`layout_engine.py` is a faithful reimplementation of the watch's
`layout_parser_json` (draw order, placeholder rules, baseline-anchored
text, arc/svg/solid semantics, 2-bit alpha, round-screen mask, hands
hub). It runs a face's real `app.js` under jerry for a chosen scenario
(`day`, `ace`, `dawn`) and rasterizes the face's real `layout.json`
over its real assets. Everything that has to know where a face puts
things goes through it, so the geometry is written down exactly once:

* `simulate.py <face>` writes `<face>/build/sim-<scenario>.png`;
  `--sheet gallery.png` renders the whole collection (see
  `gallery.png`), `--audit` checks text against the hub, the screen
  edge and other text, *and* baked background art against the hub. It
  found its first real bug on day one: the Gazette masthead was
  clipped by the round screen. The baked-art half was added later,
  after regence spent several revisions auditing clean with two date
  numerals hidden under the hands hub — text-node checks cannot see a
  face that draws its own lettering.
* `gen_assets.render_preview()` draws the companion-app thumbnail and
  the on-watch `!preview.rle` the same way — the real values the face
  computes for the `day` scenario, in the real places. A new face
  therefore needs no preview code at all, and previews can't drift
  from the layout (the old hand-written ones had: Sector's date sat
  below its window and showed `7.2k` where the face renders `7234`).

`FACES`/`NOT_BUNDLED` also live in `layout_engine.py`; `build.py`,
`test.py` and `simulate.py` import them.

`test.py` runs each `app.js` under the desktop jerry CLI
(`harness/mocks.js` + `harness/driver.js`) and asserts the full event
lifecycle: boot claim, visible→draw du4 + hands move, minute gu4 /
15-minute du4 cadence, placeholder coverage against the layout, button
forwarding, and no drawing while invisible.

## Notes

* **Hands-hub blind spot**: the physical hands attach at screen
  center, hiding a ~30 px diameter disc around (120,120) — measured on
  the watch; the docs long said 20, then 25. All layouts keep
  text/glyphs out of roughly x/y 105..135 (arcs and full-width rules
  may pass under it).  Renders draw the hub as a dark disc, sized from
  `layout_engine.HUB_R`.  Clearing it is not the same as reading
  clearly next to it: ink a couple of px outside the disc still looks
  swallowed by it, so give anything that approaches the centre real
  margin rather than the minimum the audit accepts.

* Watchface contract honored everywhere: buttons run
  `config.button_assignments` shortcuts (`open_app`) when configured
  and are otherwise handed back via `forward_input()`;
  `ui_boot_up_done` → `go_visible/home`; `theme_class` =
  `complications`; version type byte 1.
* Wrist flick is implemented in each face (the engine won't do it):
  `flick_away` parks the hands with a relative ±360° swing and a
  2.2 s `hands` timer restores time telling — same defaults as the
  GB open-source watchface.
* **Absolute text is baseline-anchored**: a text node placed
  `absolute` puts its *baseline* at `top`, so the glyphs sit above it
  (≈ `top - 0.75*ppem` .. `top + 0.25*ppem`). Painted labels and rules
  in the background art have to be positioned against that band —
  Meridian shipped once with its rows an ascent too low, under the
  hands hub and struck through by their own rules. `simulate.py`
  models the real behavior (as does its `--audit`), so render before
  flashing. Centered containers state `ascent`/`descent` and are not
  affected.
* Layout placeholders are written `"#name"` in layout JSON but filled
  from hash-less `layout_info` keys (`name`) — the engine strips the
  hash. v1.0.0.0 shipped hashed keys, which is why no text rendered.
* Layouts stay ≤ 21 nodes (the official Mechanical face proves 21
  renders; 32 is known to blank the screen).
* Value arcs on Rings run 14°..346° so the ring glyphs in the
  12 o'clock track gap stay visible.
