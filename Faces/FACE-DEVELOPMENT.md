# Watch-face development reference

How the watch's app format, layout engine and runtime actually behave —
reverse-engineered from a real Skagen Gen 6 (Fossil Hybrid HR family)
and from the official faces. Read this before writing or changing a
face in this directory; `README.md` next to it covers the faces that
ship and how to build them.

(This file came over from the standalone face-authoring repo, where it
was that repo's CLAUDE.md. A few passages still describe experiments
that lived there — a moon-phase *app*, a minimal `simple/` face, a
Home Assistant app — which were not moved; they are kept because the
lesson each one recorded applies to any face.)

## What this is

The watch faces in this directory are complication watchfaces for the
Fossil/Skagen Hybrid HR, bundled with the iOS companion app in the repo
above. They are original designs and all their art is PIL-generated.

Build with `make` here: `test.py` (a jerry-CLI harness that drives each
app.js through the event lifecycle), then `build.py`, which also copies
each `<id>.wapp` + `<id>.png` preview into `../Resources/bundled_faces/`.
`layout_engine.py` reimplements layout_parser_json on the desktop (the
real app.js under jerry for the layout_info + the face's real
`layout.json` + the real assets); `simulate.py` uses it for
pixel-faithful screenshots (scenarios day/ace/dawn, `--sheet` for a full
gallery, `--audit`) and `gen_assets.render_preview()` uses it for the
companion thumbnail, so a face's geometry is only ever written once, in
its `layout.json`. Run simulate to verify layout changes before touching
the watch.

Faces are JerryScript 2.1.0 snapshots packed into `.wapp` files with the
[Fossil-HR-SDK](https://github.com/dakhnod/Fossil-HR-SDK) tools. Both
are vendored as submodules under `vendor/`; `make deps` fetches and
builds them. Newer JerryScript versions do not work. Uploads go through
the companion app (Apps tab → "Import .wapp or firmware…") or
Gadgetbridge+adb.

## .wapp format essentials

* Outer container: `[FE 15][03 00][offset u32][size u32][body][crc32c u32]`.
  Body starts at offset 12 with the 4 version octets from `app.json`.
* **The first octet of `app.json`'s `version` is the file TYPE byte**:
  `1` = watchface (companion app auto-activates it as the dial),
  `2` = app (menu entry). Never "bump" it. Bump the later octets so
  reinstalls replace cleanly.
* Sections in order: code, icons, layout, display_name, config
  (`pack.py` requires all five dirs under `files/`, empty ok).
  Each entry: `[name_len+1 u8][name\0][size u16][data]` — so no single
  file may exceed 65535 bytes.
* **Hard cap: the firmware rejects APP_CODE uploads > 163840 bytes**
  (160 KiB) with status 134, regardless of free storage. This is why
  the moon app ships only 12 of its 24 moon frames.
* Watchfaces should ship a `theme_class` file in the display_name
  section: `"complications"` (Gadgetbridge faces) or `"static"`
  (official Dashboard). Apps don't have one.
* The identifier in `app.json` = the code file name = the name the
  watch lists; `display_name` is cosmetic.
* The build here also packs a `description` file into the display_name
  section (from a `description` key in each face's `app.json`) — the
  one-line blurb the iOS companion shows under the face name in its
  Bundled list (`WappReader.description(fromWapp:)`). The watch
  resolves section files by name, so an extra entry there is inert.

## Layout engine (layout_parser_json)

Documented node types: `container`, `text` (ppem, color 0–3 =
black→white), `image` (`image_name`), `solid`. Placeholders: any value
may be `"#name"`, filled per-draw from `layout_info` — including
`image_name`, so images can be swapped at runtime by name.
**The `layout_info` key omits the hash**: layout `"#steps"` is filled
by `layout_info.steps` (see moonphase/simple app.js). Passing the key
*with* the hash silently resolves nothing — text renders empty and
placeholder arcs don't draw (bit the bundled faces once).

Undocumented types (reverse-engineered from the official
`Dashboard.wapp`, see analysis below):

* `svg_image` — `svg_format.path` with an SVG path string `d`,
  `color`, `scale`, `centerX`/`centerY` pivot, and `rotation` (works
  as a runtime placeholder). **This is how official faces draw
  rotating hands** — no pre-rendered images needed. Placement
  contract (verified against Dashboard's arc centers, and in use by
  `simple/`): `placement` positions the path origin; the on-screen
  pivot lands at `(left + centerX*scale, top + centerY*scale)`;
  rotation is degrees clockwise, 0 = as drawn. No `dimension` member.
  Proven path commands: `M`, `V`, `H`, relative `a`, `Z` (decimals ok).
* `arc` — `arc_info`: `center_x/y`, `radius`, `border_width`,
  `start_angle`/`end_angle` (placeholders ok), `is_filled` — ring
  gauges.
* `draw_mode: 1` appears on image/svg nodes in official faces.

**Hard limit, found the hard way: a layout with 32 nodes (37
layout_info entries) renders a completely BLANK screen.** Proven-good:
14 nodes / ~22 info entries (moon face), the official Activity face
runs 17 nodes / ~8 info entries, and the official Mechanical_Black
face runs 21 nodes (4.1 KB layout) — so the ceiling is somewhere
between 21 and 32 nodes, or it's really total layout+info JSON size.
Keep layouts small; bake static art into a background image.

**Node array order must be monotonic by `id` — inserting a node
mid-array with an out-of-order id BLANKS the whole screen.** Found the
hard way in `apps/home_assistant`: adding a node with `"id": 18` as the
3rd array element (order `0, 1, 18, 2, 3, …`) rendered black, both as an
`image` and as an `arc` node; moving the exact same node to the end of
the array (order `0, 1, 2, … 18`) rendered fine. Every working layout in
this repo (moon, `simple/`, the faces) has array order == id order.
So: give a new node the next free id and append it at the end of the
array (or renumber to keep order == id), never splice it in the middle.
Draw order is array order, but a thin overlay (e.g. a bezel ring that
doesn't cross icons/text) is unaffected by drawing last.

More layout capabilities (from the official Activity face):

* **`#common.<field>` placeholders** — text nodes can bind engine data
  directly (`"text": "#common.step_count"`, `.calories`,
  `.battery_soc`) with **no code involvement at all**.
* **Absolute text hangs off its BASELINE** — for a text node with
  `placement.type: absolute`, `top` is the baseline, not the top of
  the glyph box: the string occupies roughly `top - 0.75*ppem` ..
  `top + 0.25*ppem`. Proof: the moonphase app centers a ppem-32 hour
  on a point with `y + 10` (and `x - 25` for the width), which only
  works baseline-anchored. Getting this wrong pushes text a whole
  ascent out of place — it put a Meridian row under the hands hub and
  ran the row rules straight through the text on-watch.
  `layout_engine.py` models it correctly (so both `simulate.py`
  and the generated previews do); centered containers are unaffected
  (they state `ascent`/`descent` explicitly).
* **Centered text** — wrap the text node in a small `container`
  (`main_alignment: 1`, `cross_alignment: 1`) and give the text child
  `"placement": {"type": "relative"}` plus `ascent`/`descent` (e.g.
  12/3 at ppem 18). This is the official centering idiom — absolute
  text nodes are left-aligned.
* **Filling gauges** — a fixed-width `solid` (color 3) whose `top` and
  `height` are placeholders, drawn *under* the background image
  (node order = draw order; the background comes later with
  `draw_mode: 1`). The background has transparent windows (segmented
  arc shapes) that mask the rectangle into a gauge, and a grey
  (color 1) `solid` panel behind everything shows through as the
  "empty" track. Fill math (battery, window y 45..195):
  `height = round(soc * 1.5); top = 195 - height` — i.e. bottom-anchored
  fill = window_bottom − height.

## Icon/image formats

`image_compress.py -f rle`: `[w u8][h u8]` then `(count,pixel)` byte
pairs, terminated `FF FF`. Pixel = 2-bit grey | 2-bit **inverted
alpha** << 2 — so transparent-PNG pixels stay transparent on the
watch and images composite over each other (used for the drawn hands
in `simple/`; mostly-transparent images compress to a few hundred
bytes). Max dimensions 255×255. `-f raw` is the 2-bit no-alpha
background format (`background.raw` in GB faces).

## App runtime model

An app is `return { node_name, manifest:{timers:[...]}, config, init,
handler, ... }` compiled with `jerry-snapshot generate -f ''`. The
engine calls `init()` once and `handler(event, response)` per event;
you act by filling `response` (`draw`, `move`, `action`) — see
`app.js` and `simple/app.js` for the state-machine pattern
(`state_machine` global, `sm.n` current state, `sm.d(state)` /
aliased `new_state`).

Key events: `system_state_update` (`event.de` = concerns this app,
`event.le` = `'visible'`/...), `timer_expired` (check
`is_this_timer_expired(event, node, name)`), `time_telling_update`,
`common_update`, `ui_boot_up_done`, buttons
(`top/middle/bottom_press|_hold|_short_press_release`), `flick_away`.

Engine globals: `get_unix_time()`, `common` (year/month (0-based)/date,
`time_zone_local` in minutes, `step_count`, `battery_soc`, `calories`,
`hr_bpm` (0/absent until an HRM reading), `active_minutes`,
`daily_goal.steps`, `device_offwrist`, `weatherInfo` after a
`req_data('"weatherInfo":{}', ...)` answer — `{alive, unit, temp int°,
cond_id, rain, uv}`, cond_id per GB icon table: 0/1 clear d/n,
2 cloudy, 3/4 partly d/n, 5 rain, 6/7 snow, 8 storm, 10 wind),
`get_common()`, `enable_time_telling()` (returns
`{hour_pos, minute_pos}` for `response.move`),
`disable_time_telling()`, `start_timer(node, name, ms)`,
`stop_timer`, `localization_snprintf`, `req_data` (log channel),
`forward_input`, `deep_fill`, `is_empty_string`, `is_button_event`
(official faces).

Draw: `response.draw = {update_type:'du4'}` (full) or `'gu4'`
(partial); official faces also use `'gc4'` hourly with
`skip_invert:true` (ghost-clean). Then
`response.draw[node_name] = {layout_function:'layout_parser_json',
layout_info:{json_file:'<layout>', ...placeholders}}`.

Physical hands: `response.move = {h:deg, m:deg, is_relative:false}`.

Config can be pushed from the phone at runtime
(`<identifier>._.config.<key>`, e.g. Gadgetbridge's Q_PUSH_CONFIG
broadcast or the companion app);
the engine merges it into `this.config`.

## Watchface duties (vs plain apps) — all bitten in practice

1. **Handle button events** (they carry `event.is_button_event`):
   check `config.button_assignments` (`[{button_evt, name}]`) and
   respond `{action: {type:'open_app', node_name, class:'watch_app'}}`
   (the GB open-source face does exactly this); for unassigned events
   still call `forward_input(event, [], {})` so the system/master
   path (`master._.config.buttons`, pushed by the iOS app) can run.
   Real `forward_input(event, node_list, collector)` semantics (GB
   source): dispatches the event to the named complication nodes and
   collects their responses into `collector` — the `[]` call is the
   degenerate "let it bubble" form.
2. **Answer `ui_boot_up_done`** with
   `response.action = {type:'go_visible', class:'home'}` or the face
   won't reclaim the screen after a watch reboot.
3. Ship `theme_class` (see format section).
4. **Implement wrist-flick yourself** — the engine does not move the
   hands away for you. GB pattern (open_source_watchface.js):
   on `flick_away` → `disable_time_telling()`, `response.move =
   {h:360, m:-360, is_relative:true}`, `start_timer(node,'hands',
   2200)`; on the `hands` timer → `enable_time_telling()` + absolute
   move back to `hour_pos/minute_pos`. Guard `time_telling_update`
   while parked or it snaps the hands back early.

## Adding a bundled face

A face is a directory `<name>/` here with four hand-written files plus
a few touchpoints in the shared tooling. The fastest path is to copy an
existing face and rewrite the parts that differ.

**Per-face files**

* `app.json` — one line: `version` (type byte **1** = watchface),
  `identifier` (`<name>Face`, must equal the code file name and the
  layout id), `display_name`, `description` (the companion-list blurb),
  `layout_name` (`<name>_layout`).
* `app.js` — the face logic. Every face shares the same lifecycle
  boilerplate (boot claim → `go_visible/home`, visible/hidden,
  60 s `tick` with a du4 every 15th minute, `time_telling_update`,
  wrist-flick park+restore, `button_assignments`/`forward_input`,
  `check_start_app`); **only `compute()` and its helpers differ**. Copy
  `glass/app.js` (plain) or `meteo/app.js` (weather via
  `req_data('"weatherInfo":{}', 5000, true)` on entry + every 5 min).
  `compute()` must return `json_file` **plus every placeholder the
  layout references, on every draw** — the test fails on a missing key,
  so emit `'--'` (or a zero angle) when live data is absent. es5.1: no
  `Date`; weekday via the Sakamoto helper the faces carry; local
  minute-of-day via `get_unix_time()/60 + common.time_zone_local`.
* `layout.json` — the node array (see Layout engine). Keep it ≤ 21
  nodes, ids monotonic == array order, and **append** new nodes at the
  end (mid-array insert with an out-of-order id blanks the screen).
* No separate asset files — all art comes from `gen_assets.py`.

**Registration (one list + gen_assets.py)**

* Add `<name>` to `FACES` in `layout_engine.py` — build.py, test.py and
  simulate.py all import that one list.
* In `gen_assets.py`: write `bg_<name>()` returning a 240×240 PIL image
  and add it to the `BACKGROUNDS` dict; for a sprite-swapping face, add
  a `render_*` helper and a branch in `render()` that `save()`s each
  sprite at its size. **Nothing else** — the preview (companion
  thumbnail / gallery tile / on-watch `!preview.rle`) is rendered from
  the face's own `layout.json` with the values its app.js computes for
  the `day` scenario, so it can't drift from the real face.
* Faces are copied into the iOS companion (`<id>.wapp` + `<id>.png`)
  unless the name is in `layout_engine.py`'s `NOT_BUNDLED`.

**Build & verify (run from this directory)**

* `python3 test.py <name>` — drives app.js through the full event
  lifecycle under the jerry CLI and asserts placeholder coverage, boot
  claim, hands move, tick cadence, button forwarding, and flick. Add a
  face-specific `if face == '<name>':` assert block to pin the computed
  values.
* `python3 build.py <name>` — render art → RLE-compress → jerry-snapshot
  → pack the `.wapp` (asserts type byte 1, node ≤ 21, section ≤ 64 KiB).
  The preview goes through `layout_engine.py`, so building a face needs
  a working jerry CLI as well as jerry-snapshot.
* `python3 simulate.py <name>` — the **faithful** renderer (real app.js
  under jerry + the real `layout.json`/RLE through
  `layout_engine.py`). Run this before flashing; it catches the
  round-screen clip, hub collisions, baseline drift, and low-contrast
  bugs the lifecycle harness cannot. `--sheet out.png` for a gallery,
  `--scenario day|ace|dawn`; always check `dawn` (no weather, HR 0,
  fresh charge) to confirm the face degrades gracefully.

**PIL art conventions (`gen_assets.py`)**

* Draw in plain greys `BLACK 0 / DARK 85 / LITE 170 / WHITE 255` — they
  map straight to layout color indices 0..3. Everything is supersampled
  ×4 (`SS`) then downscaled; put coordinates through `P()` and reuse the
  shared helpers (`line`, `circle`, `arc`, `text`, `ticks`, `pol`, the
  `*_font()` families, glyphs `heart`/`sun`/`bolt`/`invader`). Round
  screen: keep art within radius ~118 of centre.
* **Minimum legible on-watch text is ppem 14 for the serif face**
  (`serif_font`) — anything smaller is unreadable on the panel. Never
  emit `serif_font(<14)` for on-dial labels; if numerals won't fit at
  14, enlarge/shift the scale, thin the label set, or rotate the text
  tangentially instead of shrinking it (found on the regence date ring).
* **Masked-solid gauge**: draw the fill `solid` *before* the background
  (lower id), give the background `draw_mode: 1`, and punch the gauge
  window transparent inside `bg_*` with
  `d.rectangle(P(...), fill=CLEAR)` (see piet/glass/aquarium/thermo/
  bios). The fill's `top`/`height` (or `left`/`width`) are placeholders;
  bottom-anchored fill = `window_bottom − height`.
* **`svg_image` needle/pointer**: only `M H V a Z` path commands render
  (on-watch *and* in `layout_engine.py` — no `L`). Build shapes from
  rectangles + relative `a` arcs (a filled disc is
  `M0,-r a r,r 0 1 0 0,2r a r,r 0 1 0 0,-2r Z`). A needle pivoting at
  the screen centre (120,120) is fine even though the hub hides its
  inner ~30 px — the tip near the rim reads (radar/compass/vault/orrery
  all pivot at centre). Off-centre sub-dial pivots also work.
* Keep every value slot (and important art) out of the hub blind spot
  ~x/y 105..135; full-width rules and rings passing under it are fine.

## Activity.wapp analysis (official face, pulled off the watch)

18.9 KB watchface (type 1, theme_class "static"): 3.4 KB code,
background + preview, 3.3 KB layout (17 nodes), no icons beyond the
background. Displays six values + two gauges:

* steps (top), calories (left), distance (right), BPM (bottom-left),
  temperature (bottom-right), battery % (bottom-center)
* steps/calories/battery are pure `#common.*` layout bindings; the
  code only computes `#distance`
  (`unit_convert_distance(common.distance).toFixed(1)`, meters in),
  `#ft` (BPM) and `#gt` (temp) — the latter two show "– –" until live
  data arrives (HR sensor readings / weather).
* Gauges: left arc F↔E = battery, right arc G↔S = steps-vs-goal, both
  the masked-solid technique described in the layout section. The
  side windows are ~150 px tall (y 45..195); the tick separators are
  opaque background pixels splitting the window into segments.
* Weather: the face polls the phone with
  `req_data(node, '"weatherInfo":{}', 5000, true)` (5 s timeout,
  `stop_req_timeout`) on entry and every redraw. GB answers by pushing
  `{"res":{"id":0,"set":{"weatherInfo":{"alive":<unix expiry>,
  "unit":"c","temp":<°C int>,"cond_id":<icon id>}}}}` (see
  `FossilHRWatchAdapter.onSendWeather`), which lands in
  `common.weatherInfo`. Internally the face stores temp ×20
  (fixed-point 1/20°, default 420 = 21.0 °C) and runs it through
  `unit_convert_temp` / `unit_setting`.
* `flick_away` → whimsical `{move: {h: 360, m: -360, is_relative:
  true}}` (physical hands spin one full opposing turn) + redraw.
* Same skeleton as Dashboard otherwise: timers `update_du4` 15 min /
  `update_gc4` 1 h + `hands` + `alive_timer`, `skip_invert: true`,
  `ui_boot_up_done` → go_visible/home, dormant
  `button_assignments`/`open_app` template code.
* Sandbox limits (harness with mocked engine): the BPM/TEMP slots and
  the steps gauge stayed at their hidden/placeholder values under
  every input shape tried — they're gated on engine-delivered inputs
  (real HRM stream, the actual req_data response path) that mocks
  don't reproduce; the fill mechanism itself is fully decoded via the
  battery gauge.

## Dashboard.wapp analysis (official face, pulled off the watch)

23.7 KB: 2 KB code, background + preview, 1.7 KB layout, no hand
images. Hands/gauges are `svg_image`/`arc` nodes fed five numbers per
redraw. Sub-dials: left = battery (soc×3.6°), bottom = weekday
(pointer + ~51° arc segment), right = steps/goal (needs complication
config; pinned 360° in sandbox probes). No SDK state machine — a
plain if/else event handler; redraws du4 every 15 min + gc4 hourly.
Official button path reads `config.button_assignments` →
`{action:{type:'open_app', ...}}` (never triggered in probes; the
forward_input path is what our setup uses).
Unpacker: the SDK's `tools/unpack.py`.

## Running watch code on the Mac (snapshot harness)

JerryScript snapshots can be executed and probed locally — this is how
Dashboard and the GB openSourceWatchface were reverse-engineered, and
how `simple/` is regression-tested without a watch:

1. Rebuild jerry with error messages:
   `python3 tools/build.py --snapshot-exec=on --jerry-cmdline-snapshot=on
   --profile=es5.1 --error-messages=on --line-info=on --builddir=.../build-errmsg`
   (the stock build has messages off — ReferenceErrors are blank).
2. C harness: `jerry_init` → register `print` → `jerry_eval(mocks.js)`
   → `jerry_exec_snapshot(..., JERRY_SNAPSHOT_EXEC_COPY_DATA)` → store
   result as global `app` → `jerry_eval(driver.js)`.
3. mocks.js: stub every engine global above (incl. a reconstructed
   `state_machine`); driver.js: call `app.init()`, then
   `app.handler(event, response)` and print responses.
4. Trace what the code reads with `Object.defineProperty` getters on
   event/common/config objects. Two blind spots: reassigning mock
   globals from driver.js after snapshot exec does NOT affect the
   snapshot's bindings (bake behavior into mocks.js; mutating object
   *properties* like `common.x = 1` works fine), and getters only log
   fields you defined — reads of undefined fields are invisible.
5. Counting `event.type` getter hits reveals the size of the
   handler's type-comparison chain (Dashboard: 8, Activity: 12); the
   ordered literal pool (regex over the file, first-seen order) shows
   *which* strings it compares and roughly which branch reads what.

`strings -n 4 <snapshot>` on a `.bin`/code file is a fast first pass
(JRRY magic, literal pool reveals events/globals used).

## Misc gotchas

* **Hands-hub blind spot**: the physical hands attach at the screen
  center — a ~30 px diameter disc around (120,120) is never visible
  (measured on the watch; the docs long said 20, then 25). Keep
  text/glyphs out of roughly x/y 105..135; ring arcs and decorative
  lines passing under it are fine. `layout_engine.HUB_R` (15.0) is the
  one place the renderer and simulate.py's --audit take it from.
  Clearing the disc is not the same as reading clearly beside it — the
  audit's `HUB_R + 2` is a collision margin, and ink that only just
  passes it still looks swallowed by the hub.
  `simulate.py --audit` checks this on two fronts, because they fail
  independently: `text` nodes (values the watch fills in) via their
  glyph boxes, and **baked background art** via the pixels. The second
  exists because the first sees nothing on a face that draws its own
  lettering in `gen_assets.py` — regence audited clean for several
  revisions with two date numerals sitting under the hub. Rings and
  rules passing under the hub stay legal: the pixel check flood-fills
  the ink and only reports components small enough to be a *mark*
  (bbox ≤ 34 px) that lose ≥ 6 px to the hub, so a numeral is caught
  and a sunburst ray or guilloche ring crossing the centre is not.
  Regence's date ring is
  the worked example: 1 and 31 sat 2.7 px outside the disc as it was
  then measured, passed the audit, and read as hidden; its opening was
  widened until they stand 20.8 px out from the centre — 5.8 px clear
  of the hub at 15.0, and still clear if it is measured larger again.

* **Stale `__pycache__` can outlive an edit to `gen_assets.py`.**
  Python revalidates a `.pyc` on (source mtime, source size), so a
  change that keeps the file the same length — swapping one constant
  for another of equal width, e.g. `15 + (d-1)*(330.0/30.0)` for
  `27 + (d-1)*(306.0/30.0)` — and lands in the same second as the
  recorded mtime is not noticed. Every later process then runs the old
  bytecode while the source reads correctly, and `inspect.getsource`
  agrees with the source, so the two disagree with no warning. Hit
  while A/B-ing a face's geometry. `rm -rf Faces/__pycache__` between
  A/B builds; if a rendered face contradicts the source, check this
  before disbelieving the source.

* `jq -r` leaves a trailing newline in `display_name` — harmless.
* jerry es5.1: no `Date`, quote reserved words used as keys
  (`"class"`), guard optional engine globals with `typeof`.
* To reset the watch: hold middle until it vibrates. **Never choose
  "Reset and disconnect"** — it wipes the menu and needs a factory
  re-pair.
* The iOS companion auto-deletes the old same-identifier app before
  reinstalling; it reads the type byte at offset 12 to decide
  app-vs-watchface (`WappReader`).
