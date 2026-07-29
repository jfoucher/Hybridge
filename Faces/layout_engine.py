#!/usr/bin/env python3
"""A desk-side reimplementation of the watch's layout_parser_json.

This is the single place that knows where a face puts things: it reads
the face's real `layout.json` and its real built assets and draws what
the watch would draw.  Both consumers go through it, so nothing has to
restate a face's geometry:

  * `simulate.py` — screenshots/contact sheet/audit, real RLE assets;
  * `gen_assets.py:render_preview()` — the companion-app thumbnail and
    the on-watch `!preview.rle`, drawn over the source PNG assets.

Semantics implemented here, as reverse-engineered in CLAUDE.md: node
order = draw order, '#name' placeholders filled from hash-less
layout_info keys, '#common.*' engine bindings, absolute text hanging
off its baseline, centered-text containers (ascent/descent), arc nodes
(0 deg = 12 o'clock, clockwise), solid nodes under transparent
background windows (masked gauges), svg_image paths (M/H/V/a/Z) scaled
and rotated about their pivot, and 2-bit grey + 2-bit alpha
compositing.

The layout_info itself is produced by running the face's real app.js
under the desktop jerry CLI for one of the SCENARIOS below — so the
values in a preview are the values the watch computes, not samples.
"""
import json
import math
import os
import re
import subprocess

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)            # the companion-app repo

# The toolchain lives in the two vendored submodules; `make deps` clones
# and builds them.  Everything that shells out to jerry or to an SDK tool
# resolves it from here, so the paths are written down exactly once.
VENDOR = os.path.join(HERE, 'vendor')
JERRY_DIR = os.environ.get('JERRY_DIR', os.path.join(VENDOR, 'jerryscript'))
SDK_TOOLS = os.environ.get(
    'FOSSIL_SDK_TOOLS', os.path.join(VENDOR, 'Fossil-HR-SDK', 'tools'))

# Snapshots are compiled by the stock build (error messages off, as the
# watch has them); the error-message build is what test.py/simulate.py
# run scripts under, since a stock ReferenceError prints blank.  Either
# build runs scripts fine when it is the only one around.
JERRY_SNAPSHOT = os.path.join(JERRY_DIR, 'build', 'bin', 'jerry-snapshot')
JERRY = os.path.join(JERRY_DIR, 'build-errmsg', 'bin', 'jerry')
if not os.path.exists(JERRY):
    JERRY = os.path.join(JERRY_DIR, 'build', 'bin', 'jerry')

# every face, in gallery order — build.py/test.py/simulate.py share this
FACES = ['sector', 'meteo', 'rings', 'pulse', 'daily',
         'fluted', 'reserve', 'tty', 'radar',
         'retro', 'gnomon', 'iris', 'piet', 'glass', 'arcade',
         'gazette', 'schema', 'transit', 'calc', 'todo', 'grande', 'grande2',
         'horizon', 'meridian', 'almanac',
         'split', 'stack', 'type',
         'rayon', 'deco', 'aria', 'ivory', 'seigaiha', 'argyle', 'wicker',
         'reptile', 'regence']

# built faces ship inside the iOS companion app — all but these
NOT_BUNDLED = {'calc', 'glass', 'gnomon', 'grande', 'iris',
               'radar', 'schema', 'transit', 'tty', 'argyle', 'wicker'}

GREY = [0, 85, 170, 255]
FONT = '/System/Library/Fonts/Helvetica.ttc'   # stand-in for the watch font
FONT_INDEX = 1                                # Bold
SS = 4                                        # supersample for arcs/text
HUB_R = 12.5    # the hands hub measured ~25 px across on the watch

# ------------------------------------------------------------- scenarios
#
# Each scenario is the `common` state the app sees plus a local time.
# get_unix_time() is derived so that time-of-day faces agree with it.

SCENARIOS = {
    # an ordinary afternoon
    'day': dict(hour=15, minute=8, step_count=7234, calories=486,
                battery_soc=78, active_minutes=42, hr_bpm=72,
                weather=dict(temp=21, unit='c', cond_id=3, rain=30, uv=5)),
    # everything achieved, evening
    'ace': dict(hour=21, minute=52, step_count=13210, calories=812,
                battery_soc=100, active_minutes=95, hr_bpm=64,
                weather=dict(temp=17, unit='c', cond_id=1, rain=10, uv=0)),
    # fresh off the charger, nothing has happened yet, phone silent
    'dawn': dict(hour=6, minute=30, step_count=112, calories=8,
                 battery_soc=100, active_minutes=0, hr_bpm=0,
                 weather=None),
}


def layout_info_for(face, scenario='day'):
    """Run the face's real app.js under jerry; return (layout_info, common)."""
    sc = SCENARIOS[scenario]
    # 2026-07-18 00:00 UTC is epoch 1784678400; tz +120 like the watch
    tz = 120
    epoch = 1784678400 + (sc['hour'] * 60 + sc['minute'] - tz) * 60

    prelude = f"""
var common = {{
    year: 2026, month: 6, date: 18, time_zone_local: {tz},
    step_count: {sc['step_count']}, calories: {sc['calories']},
    battery_soc: {sc['battery_soc']},
    active_minutes: {sc['active_minutes']}, hr_bpm: {sc['hr_bpm']},
    daily_goal: {{ steps: 10000, calories: 400 }}
}};
function get_unix_time() {{ return {epoch}; }}
"""
    if sc['weather']:
        w = dict(sc['weather'])
        w['alive'] = epoch + 3600
        prelude += f'common.weatherInfo = {json.dumps(w)};\n'

    mocks = open(os.path.join(HERE, 'harness', 'mocks.js')).read()
    # scenario prelude overrides the harness defaults
    mocks = mocks + prelude

    app = open(os.path.join(HERE, face, 'app.js')).read()
    driver = """
app.init();
var r = {};
app.handler({ type: 'system_state_update', de: true, le: 'visible' }, r);
print('INFO ' + JSON.stringify(r.draw[''].layout_info));
"""
    src = mocks + '\nvar app = (function () {\n' + app + '\n})();\n' + driver
    tmp = os.path.join(HERE, face, 'build', 'sim-driver.js')
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    open(tmp, 'w').write(src)
    proc = subprocess.run([JERRY, tmp], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f'{face}: jerry failed\n{proc.stdout}{proc.stderr}')
    for line in proc.stdout.splitlines():
        if line.startswith('INFO '):
            return json.loads(line[5:]), dict(sc, distance=0)
    raise RuntimeError(f'{face}: no layout_info in output')


def load_layout(face):
    """The face's hand-written layout.json — the same file build.py packs."""
    with open(os.path.join(HERE, face, 'layout.json')) as f:
        return json.load(f)


# ------------------------------------------------------------ RLE images

def decode_rle(data):
    w, h = data[0] or 256, data[1] or 256
    px = []
    i = 2
    while i + 1 < len(data):
        n, p = data[i], data[i + 1]
        if n == 0xFF and p == 0xFF:
            break
        px.extend([p] * n)
        i += 2
    img = Image.new('RGBA', (w, h))
    out = []
    for p in px[:w * h]:
        g = GREY[p & 3]
        a = 255 - GREY[(p >> 2) & 3]
        out.append((g, g, g, a))
    out += [(0, 0, 0, 0)] * (w * h - len(out))
    img.putdata(out)
    return img


def load_icons(face):
    """The compiled RLE icons, exactly as the watch will see them."""
    icons = {}
    d = os.path.join(HERE, face, 'build', 'files', 'icons')
    for name in os.listdir(d):
        if name.startswith('!'):
            continue
        icons[name] = decode_rle(open(os.path.join(d, name), 'rb').read())
    return icons


def load_icons_png(png_dir):
    """The pre-compression PNGs from gen_assets.render().

    Same pixels, minus the 2-bit quantization — used for previews so the
    companion-app thumbnails keep their antialiasing."""
    icons = {}
    for name in os.listdir(png_dir):
        if not name.endswith('.png') or name.startswith('!'):
            continue
        icons[name[:-4]] = Image.open(
            os.path.join(png_dir, name)).convert('RGBA')
    return icons


# --------------------------------------------------------------- helpers

def resolve(value, info, common):
    """Fill a '#name' placeholder from layout_info (hash stripped) or a
    '#common.field' engine binding."""
    if isinstance(value, str) and value.startswith('#'):
        if value.startswith('#common.'):
            return common.get(value[8:], 0)
        return info.get(value[1:], value)
    return value


def svg_path_points(d_attr):
    """Parse the proven watch dialect: M, H, V, a (relative), Z.
    Returns a list of sub-paths (each a list of points); every 'M' starts a
    new sub-path so multiple shapes in one path fill independently."""
    tokens = re.findall(r'[MHVaZz]|-?[\d.]+', d_attr.replace(',', ' '))
    subs, cur, pos, i = [], [], (0.0, 0.0), 0
    while i < len(tokens):
        cmd = tokens[i]
        i += 1
        if cmd == 'M':
            if cur:
                subs.append(cur)
            pos = (float(tokens[i]), float(tokens[i + 1]))
            i += 2
            cur = [pos]
        elif cmd == 'H':
            pos = (float(tokens[i]), pos[1])
            i += 1
            cur.append(pos)
        elif cmd == 'V':
            pos = (pos[0], float(tokens[i]))
            i += 1
            cur.append(pos)
        elif cmd == 'a':
            rx, ry = float(tokens[i]), float(tokens[i + 1])
            large, sweep = int(float(tokens[i + 3])), int(float(tokens[i + 4]))
            dx, dy = float(tokens[i + 5]), float(tokens[i + 6])
            i += 7
            cur.extend(arc_points(pos, rx, ry, large, sweep, dx, dy))
            pos = cur[-1]
        elif cmd in 'Zz':
            if cur:
                cur.append(cur[0])
    if cur:
        subs.append(cur)
    return subs


def arc_points(p0, rx, ry, large, sweep, dx, dy, n=24):
    """Endpoint-parameterised elliptical arc -> sampled points."""
    x1, y1 = p0
    x2, y2 = x1 + dx, y1 + dy
    # center parameterisation (rotation 0), per SVG spec appendix
    xm, ym = (x1 - x2) / 2, (y1 - y2) / 2
    lam = (xm / rx) ** 2 + (ym / ry) ** 2
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s
    num = rx**2 * ry**2 - rx**2 * ym**2 - ry**2 * xm**2
    den = rx**2 * ym**2 + ry**2 * xm**2
    c = math.sqrt(max(0, num / den)) if den else 0
    if large == sweep:
        c = -c
    cxm, cym = c * rx * ym / ry, -c * ry * xm / rx
    cx, cy = cxm + (x1 + x2) / 2, cym + (y1 + y2) / 2

    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        length = math.hypot(ux, uy) * math.hypot(vx, vy)
        a = math.acos(max(-1, min(1, dot / length)))
        return -a if ux * vy - uy * vx < 0 else a

    a1 = angle(1, 0, (xm - cxm) / rx, (ym - cym) / ry)
    da = angle((xm - cxm) / rx, (ym - cym) / ry,
               (-xm - cxm) / rx, (-ym - cym) / ry)
    if not sweep and da > 0:
        da -= 2 * math.pi
    if sweep and da < 0:
        da += 2 * math.pi
    return [(cx + rx * math.cos(a1 + da * t / n),
             cy + ry * math.sin(a1 + da * t / n)) for t in range(1, n + 1)]


def text_metrics(node, parent, info, common, slop=1.0):
    """Where a text node's string lands, in screen coordinates.

    Returns (string, box, anchor_point, anchor) — `box` is the glyph
    bounding box (x0, y0, x1, y1), `anchor_point` and `anchor` are what
    PIL needs to draw it there.  `slop` widens the box to allow for the
    watch font's metrics differing from the stand-in."""
    s = str(resolve(node['text'], info, common))
    ppem = node['ppem']
    font = ImageFont.truetype(FONT, ppem, index=FONT_INDEX)
    tw = font.getbbox(s)[2] * slop
    if node.get('placement', {}).get('type') == 'relative' and parent:
        # centered idiom: the child states its own ascent/descent and is
        # centered in the parent container
        p = parent.get('placement', {})
        dim = parent.get('dimension', {})
        pl = resolve(p.get('left', 0), info, common)
        pt = resolve(p.get('top', 0), info, common)
        pw = resolve(dim.get('width', 0), info, common)
        ph = resolve(dim.get('height', 0), info, common)
        asc = node.get('ascent', round(ppem * 0.65))
        desc = node.get('descent', 3)
        baseline = pt + (ph - (asc + desc)) / 2 + asc
        cx = pl + pw / 2
        return s, (cx - tw / 2, baseline - asc, cx + tw / 2,
                   baseline + desc), (cx, baseline), 'ms'
    # absolute text hangs off its BASELINE, not the top of the glyph box
    p = node.get('placement', {})
    left = resolve(p.get('left', 0), info, common)
    top = resolve(p.get('top', 0), info, common)
    asc = node.get('ascent', round(ppem * 0.75))
    desc = node.get('descent', round(ppem * 0.25))
    return s, (left, top - asc, left + tw, top + desc), (left, top), 'ls'


# -------------------------------------------------------------- renderer

def draw_layout(layout, info, icons, common=None, mask=True, hub=True):
    """Rasterize a layout the way the watch would; returns a 240x240 RGBA.

    `mask` clips to the round screen (off for previews — the companion
    app clips them itself); `hub` paints the physical hands' blind spot.
    """
    common = common or {}
    img = Image.new('RGBA', (240 * SS, 240 * SS), (0, 0, 0, 255))
    d = ImageDraw.Draw(img)
    nodes = {n['id']: n for n in layout}

    def box(node):
        p = node.get('placement', {})
        dim = node.get('dimension', {})
        return (resolve(p.get('left', 0), info, common),
                resolve(p.get('top', 0), info, common),
                resolve(dim.get('width', 0), info, common),
                resolve(dim.get('height', 0), info, common))

    for node in layout:
        if not node.get('visible', True):
            continue
        kind = node['type']

        if kind == 'container':
            continue

        if kind == 'solid':
            left, top, w, h = box(node)
            g = GREY[node.get('color', 3)]
            d.rectangle([left * SS, top * SS, (left + w) * SS,
                         (top + h) * SS], fill=(g, g, g, 255))

        elif kind == 'image':
            name = resolve(node['image_name'], info, common)
            icon = icons.get(name)
            left, top, _, _ = box(node)
            if icon is None:
                d.rectangle([left * SS, top * SS, (left + 20) * SS,
                             (top + 20) * SS], outline=(255, 0, 0, 255))
                continue
            big = icon.resize((icon.width * SS, icon.height * SS),
                              Image.Resampling.NEAREST)
            img.alpha_composite(big, (int(left) * SS, int(top) * SS))

        elif kind == 'text':
            s, _, (x, y), anchor = text_metrics(
                node, nodes.get(node.get('parent_id')), info, common)
            font = ImageFont.truetype(FONT, node['ppem'] * SS,
                                      index=FONT_INDEX)
            color = GREY[node.get('color', 3)]
            d.text((x * SS, y * SS), s, font=font,
                   fill=(color, color, color, 255), anchor=anchor)

        elif kind == 'arc':
            a = node['arc_info']
            cx = resolve(a['center_x'], info, common)
            cy = resolve(a['center_y'], info, common)
            r = resolve(a['radius'], info, common)
            bw = resolve(a['border_width'], info, common)
            a0 = resolve(a['start_angle'], info, common)
            a1 = resolve(a['end_angle'], info, common)
            g = GREY[node.get('color', 3)]
            bbox = [(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS]
            if node.get('is_filled'):
                d.pieslice(bbox, a0 - 90, a1 - 90, fill=(g, g, g, 255))
            else:
                d.arc(bbox, a0 - 90, a1 - 90, fill=(g, g, g, 255),
                      width=int(bw * SS))

        elif kind == 'svg_image':
            p = node['svg_format']['path']
            scale = p.get('scale', 1)
            rot = math.radians(resolve(p.get('rotation', 0), info, common))
            left, top, _, _ = box(node)
            pvx, pvy = left + p['centerX'] * scale, top + p['centerY'] * scale
            # on the watch the svg palette differs from text: index 0 reads
            # as white and 4 as black. Map to match the panel.
            c = p.get('color', 3)
            g = 255 if c == 0 else (0 if c >= 4 else GREY[c])
            for sub in svg_path_points(p['d']):
                pts = []
                for x, y in sub:
                    x, y = left + x * scale, top + y * scale
                    dx, dy = x - pvx, y - pvy
                    x = pvx + dx * math.cos(rot) - dy * math.sin(rot)
                    y = pvy + dx * math.sin(rot) + dy * math.cos(rot)
                    pts.append((x * SS, y * SS))
                if len(pts) >= 3:
                    d.polygon(pts, fill=(g, g, g, 255))

    if mask:
        m = Image.new('L', img.size, 0)
        ImageDraw.Draw(m).ellipse([0, 0, 240 * SS, 240 * SS], fill=255)
        img = Image.composite(img, Image.new('RGBA', img.size,
                                             (0, 0, 0, 255)), m)
    if hub:
        # the physical hands attach at the screen centre: a ~25px disc
        # there (x/y 107.5..132.5) is never visible
        d = ImageDraw.Draw(img)
        d.ellipse([(120 - HUB_R) * SS, (120 - HUB_R) * SS,
                   (120 + HUB_R) * SS, (120 + HUB_R) * SS],
                  fill=(85, 85, 85, 255))
        d.ellipse([116.5 * SS, 116.5 * SS, 123.5 * SS, 123.5 * SS],
                  fill=(170, 170, 170, 255))

    return img.resize((240, 240), Image.Resampling.LANCZOS)


def render_face(face, scenario='day', icons=None, mask=True, hub=True):
    """Draw `face` for `scenario`; returns (image, layout_info)."""
    info, common = layout_info_for(face, scenario)
    if icons is None:
        icons = load_icons(face)
    return draw_layout(load_layout(face), info, icons, common,
                       mask=mask, hub=hub), info
