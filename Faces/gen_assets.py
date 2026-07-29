#!/usr/bin/env python3
"""Render all bitmap assets for the bundled watch faces.

Everything is drawn from scratch with PIL primitives (supersampled 4x,
then downscaled); nothing here is extracted from official Fossil files.
The watch quantizes to 2-bit grey + 2-bit alpha at compress time, so we
draw in plain greys: BLACK 0, DARK 85, LITE 170, WHITE 255.
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFont

import layout_engine

SS = 4          # supersample factor
W = 240         # screen size

BLACK = (0, 0, 0, 255)
DARK = (85, 85, 85, 255)
LITE = (170, 170, 170, 255)
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)
TRANSLUCENT = (255, 255, 255, 150)

FONT_LABEL = '/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf'
FONT_VALUE = ('/System/Library/Fonts/Helvetica.ttc', 1)  # Bold — previews only
FONT_SERIF = '/System/Library/Fonts/Supplemental/Baskerville.ttc'
FONT_MONO = '/System/Library/Fonts/SFNSMono.ttf'


def label_font(px):
    return ImageFont.truetype(FONT_LABEL, px * SS)


def value_font(px):
    return ImageFont.truetype(FONT_VALUE[0], px * SS, index=FONT_VALUE[1])


def serif_font(px):
    return ImageFont.truetype(FONT_SERIF, px * SS)

def serif_font_bold(px):
    return ImageFont.truetype(FONT_SERIF, px * SS, 4)

def marker_font(px):
    return ImageFont.truetype(
        '/System/Library/Fonts/Supplemental/Bradley Hand Bold.ttf', px * SS)


def mono_font(px):
    return ImageFont.truetype(FONT_MONO, px * SS)


def canvas(size=W, bg=BLACK):
    return Image.new('RGBA', (size * SS, size * SS), bg)


def finish(img, size=None):
    size = size or img.width // SS
    if isinstance(size, int):
        size = (size, size)
    return img.resize(size, Image.Resampling.LANCZOS)


def P(*xy):
    """Scale a coordinate list into supersampled space."""
    return [v * SS for v in xy]


def line(d, pts, fill=WHITE, w=2):
    d.line(P(*pts), fill=fill, width=int(w * SS), joint='curve')


def circle(d, cx, cy, r, outline=None, fill=None, w=2):
    d.ellipse(P(cx - r, cy - r, cx + r, cy + r), fill=fill,
              outline=outline, width=int(w * SS))


def arc(d, cx, cy, r, a0, a1, fill=WHITE, w=2):
    """a0/a1 in watch convention: degrees clockwise from 12 o'clock."""
    d.arc(P(cx - r, cy - r, cx + r, cy + r),
          a0 - 90, a1 - 90, fill=fill, width=int(w * SS))


def text(d, cx, cy, s, font, fill=WHITE, anchor='mm'):
    d.text(P(cx, cy), s, font=font, fill=fill, anchor=anchor)


def ticks(d, cx, cy, r_out, n=60, minor_len=4, major_len=8, major_every=5,
          minor_w=1.2, major_w=2.5, fill=WHITE, minor_fill=None):
    for i in range(n):
        a = math.radians(i * 360.0 / n - 90)
        major = (i % major_every) == 0
        ln = major_len if major else minor_len
        wd = major_w if major else minor_w
        fl = fill if major else (minor_fill or fill)
        x0 = cx + (r_out - ln) * math.cos(a)
        y0 = cy + (r_out - ln) * math.sin(a)
        x1 = cx + r_out * math.cos(a)
        y1 = cy + r_out * math.sin(a)
        line(d, [x0, y0, x1, y1], fill=fl, w=wd)


# ---------------------------------------------------------------- glyphs

def heart(d, cx, cy, s, fill=WHITE):
    r = s * 0.30
    circle(d, cx - r, cy - s * 0.18, r, fill=fill)
    circle(d, cx + r, cy - s * 0.18, r, fill=fill)
    d.polygon(P(cx - s * 0.56, cy - s * 0.08,
                cx + s * 0.56, cy - s * 0.08,
                cx, cy + s * 0.55), fill=fill)


def flame(d, cx, cy, s, fill=WHITE):
    circle(d, cx, cy + s * 0.18, s * 0.38, fill=fill)
    d.polygon(P(cx - s * 0.34, cy + s * 0.20,
                cx + s * 0.34, cy + s * 0.16,
                cx + s * 0.10, cy - s * 0.55), fill=fill)
    circle(d, cx, cy + s * 0.22, s * 0.14, fill=BLACK)


def shoe(d, cx, cy, s, fill=WHITE):
    """Stylized footprint: sole + heel."""
    d.ellipse(P(cx - s * 0.30, cy - s * 0.55, cx + s * 0.30, cy + 0.15 * s),
              fill=fill)
    d.ellipse(P(cx - s * 0.22, cy + s * 0.25, cx + s * 0.22, cy + s * 0.60),
              fill=fill)


def bolt(d, cx, cy, s, fill=WHITE):
    d.polygon(P(cx + s * 0.18, cy - s * 0.55,
                cx - s * 0.32, cy + s * 0.10,
                cx - s * 0.04, cy + s * 0.10,
                cx - s * 0.18, cy + s * 0.55,
                cx + s * 0.32, cy - s * 0.12,
                cx + s * 0.04, cy - s * 0.12), fill=fill)


def battery(d, cx, cy, s, fill=WHITE):
    w2, h2 = s * 0.50, s * 0.32
    d.rounded_rectangle(P(cx - w2, cy - h2, cx + w2, cy + h2),
                        radius=s * 0.1 * SS, outline=fill, width=int(1.6 * SS))
    d.rectangle(P(cx + w2, cy - s * 0.12, cx + w2 + s * 0.12, cy + s * 0.12),
                fill=fill)
    d.rectangle(P(cx - w2 + s * 0.14, cy - h2 + s * 0.14,
                  cx - w2 + s * 0.52, cy + h2 - s * 0.14), fill=fill)


def sun(d, cx, cy, s, fill=WHITE):
    circle(d, cx, cy, s * 0.42, fill=fill)
    for i in range(8):
        a = math.radians(i * 45)
        x0 = cx + s * 0.62 * math.cos(a)
        y0 = cy + s * 0.62 * math.sin(a)
        x1 = cx + s * 0.95 * math.cos(a)
        y1 = cy + s * 0.95 * math.sin(a)
        line(d, [x0, y0, x1, y1], fill=fill, w=max(1.6, s * 0.09))


def moon(d, cx, cy, s, fill=WHITE):
    circle(d, cx, cy, s * 0.75, fill=fill)
    circle(d, cx + s * 0.45, cy - s * 0.35, s * 0.62, fill=CLEAR)


def cloud(d, cx, cy, s, fill=WHITE, outline=None):
    parts = [(cx - s * 0.42, cy + s * 0.10, s * 0.30),
             (cx - s * 0.02, cy - s * 0.16, s * 0.40),
             (cx + s * 0.40, cy + s * 0.10, s * 0.30)]
    base = P(cx - s * 0.62, cy + s * 0.02, cx + s * 0.62, cy + s * 0.40)
    if outline:
        # front cloud: opaque black body with a bright outline so it
        # reads as being in front of whatever is behind it
        for px, py, r in parts:
            circle(d, px, py, r, fill=BLACK)
        d.rounded_rectangle(base, radius=s * 0.2 * SS, fill=BLACK)
        for px, py, r in parts:
            circle(d, px, py, r, outline=outline, w=1.8)
        d.rounded_rectangle(base, radius=s * 0.2 * SS, outline=outline,
                            width=int(1.8 * SS))
        # re-fill the interior joins so outlines don't cross the body
        for px, py, r in parts:
            circle(d, px, py, r - 1.8, fill=BLACK)
        d.rounded_rectangle(P(cx - s * 0.62 + 1.8, cy + s * 0.02 + 1.8,
                              cx + s * 0.62 - 1.8, cy + s * 0.40 - 1.8),
                            radius=s * 0.15 * SS, fill=BLACK)
    else:
        for px, py, r in parts:
            circle(d, px, py, r, fill=fill)
        d.rounded_rectangle(base, radius=s * 0.2 * SS, fill=fill)


# ------------------------------------------------------- weather icons

def weather_icons():
    """Return {icon_name: draw_fn}; each draws on a 48x48 canvas."""
    C = 24  # icon center

    def clear_day(d):
        sun(d, C, C, 15)

    def clear_night(d):
        moon(d, C, C, 15)

    def cloudy(d):
        cloud(d, C, C, 16)

    def part_day(d):
        sun(d, C + 8, C - 8, 10)
        cloud(d, C - 2, C + 4, 13, outline=WHITE)

    def part_night(d):
        moon(d, C + 8, C - 9, 9)
        cloud(d, C - 2, C + 4, 13, outline=WHITE)

    def rain(d):
        cloud(d, C, C - 6, 13)
        for i, x in enumerate((C - 9, C, C + 9)):
            line(d, [x + 2, C + 6, x - 2, C + 15 + (3 if i == 1 else 0)],
                 fill=WHITE, w=2)

    def snow(d):
        cloud(d, C, C - 6, 13)
        for x, y in ((C - 9, C + 10), (C, C + 14), (C + 9, C + 10)):
            for a in (0, 60, 120):
                ar = math.radians(a)
                dx, dy = 3.2 * math.cos(ar), 3.2 * math.sin(ar)
                line(d, [x - dx, y - dy, x + dx, y + dy], fill=WHITE, w=1.4)

    def storm(d):
        cloud(d, C, C - 7, 13)
        bolt(d, C, C + 11, 11)

    def wind(d):
        for y, x0, x1 in ((C - 7, 6, 34), (C, 10, 42), (C + 7, 6, 30)):
            line(d, [x0, y, x1, y], fill=WHITE, w=2)
            circle(d, x1 + 1.5, y - 2, 2.4, outline=WHITE, w=1.4)

    def none(d):
        cloud(d, C, C - 2, 15)
        # question mark cut out of the cloud body
        f = label_font(16)
        d.text(P(C, C + 1), '?', font=f, fill=CLEAR, anchor='mm')

    return {'wxClearDay': clear_day, 'wxClearNight': clear_night,
            'wxCloudy': cloudy, 'wxPartDay': part_day,
            'wxPartNight': part_night, 'wxRain': rain, 'wxSnow': snow,
            'wxStorm': storm, 'wxWind': wind, 'wxNone': none}


# ---------------------------------------------------------- backgrounds

def bg_sector():
    img = canvas()
    d = ImageDraw.Draw(img)
    ticks(d, 120, 120, 119, n=60, minor_len=4, major_len=9,
          fill=WHITE, minor_fill=LITE)
    # date window under 12
    d.rounded_rectangle(P(98, 28, 142, 58), radius=4 * SS,
                        outline=LITE, width=int(1.5 * SS))
    # side sub-eyes
    for cx, glyph, lbl in ((62, heart, 'BPM'), (178, flame, 'KCAL')):
        circle(d, cx, 112, 38, outline=LITE, w=1.5)
        glyph(d, cx, 92, 13)
        text(d, cx, 133, lbl, label_font(12), fill=LITE)
    # bottom steps eye: dark track ring, filled at runtime by an arc node
    circle(d, 120, 182, 42, outline=DARK, w=4)
    shoe(d, 120, 160, 11)
    text(d, 120, 203, 'STEPS', label_font(12), fill=LITE)
    return img


def bg_meteo():
    img = canvas()
    d = ImageDraw.Draw(img)
    # battery track ring at the rim
    circle(d, 120, 120, 114, outline=DARK, w=3)
    battery(d, 120, 232, 9, fill=LITE)
    text(d, 52, 146, 'RAIN', label_font(13), fill=LITE)
    text(d, 188, 146, 'UV', label_font(13), fill=LITE)
    shoe(d, 120, 190, 10)
    return img


def bg_rings():
    img = canvas()
    d = ImageDraw.Draw(img)
    # three track rings, each broken at 12 o'clock for its glyph
    for r, glyph in ((100, shoe), (84, battery), (68, bolt)):
        arc(d, 120, 120, r, 14, 346, fill=DARK, w=10)
        glyph(d, 120, 120 - r+8, 8)
    text(d, 120, 70, 'STEPS', label_font(11), fill=LITE)
    return img


def bg_pulse():
    img = canvas()
    d = ImageDraw.Draw(img)
    heart(d, 120, 34, 24)
    # ECG trace (stays below the hands-hub blind spot at 120,120 r~12)
    y = 158
    pts = [30, y, 88, y, 97, y - 7, 106, y + 9, 114, y - 22, 124, y + 14,
           131, y, 210, y]
    line(d, pts, fill=WHITE, w=2)
    shoe(d, 75, 174, 9)
    flame(d, 165, 174, 11)
    return img


def bg_daily():
    img = canvas()
    d = ImageDraw.Draw(img)
    # divider rule, split around the hands-hub blind spot at center
    line(d, [56, 120, 104, 120], fill=LITE, w=1.5)
    line(d, [136, 120, 184, 120], fill=LITE, w=1.5)
    for y, lbl in ((150, 'STEPS'), (170, 'KCAL'), (190, 'ACTIVE'),
                   (210, 'TEMP')):
        text(d, 70, y, lbl, label_font(14), fill=LITE, anchor='lm')
    # little corner ticks flanking the big date
    ticks(d, 120, 120, 119, n=4, minor_len=0, major_len=7, major_every=1,
          fill=DARK)
    return img


def baton(d, cx, cy, angle_deg, r_in, r_out, w, fill=WHITE):
    """Radially oriented rectangular hour index."""
    a = math.radians(angle_deg - 90)
    rx, ry = math.cos(a), math.sin(a)          # radial unit vector
    px, py = -ry, rx                            # perpendicular
    pts = []
    for r, s in ((r_in, -1), (r_in, 1), (r_out, 1), (r_out, -1)):
        pts += [cx + r * rx + s * w / 2 * px, cy + r * ry + s * w / 2 * py]
    d.polygon(P(*pts), fill=fill)


def bg_fluted():
    """Classic date watch: fluted bezel, baton indices, date lens at 3."""
    img = canvas()
    d = ImageDraw.Draw(img)
    # fluted bezel: alternating bright/dim radial ridges
    for i in range(72):
        a = i * 5
        baton(d, 120, 120, a, 105, 119, 4, fill=WHITE if i % 2 else LITE)
    circle(d, 120, 120, 103, outline=LITE, w=1)
    ticks(d, 120, 120, 100, n=60, minor_len=3, major_len=6,
          fill=LITE, minor_fill=DARK)
    for h in range(12):
        if h == 3:
            continue                     # date lens lives at 3 o'clock
        if h == 0:
            baton(d, 120, 120, -3.2, 70, 92, 4)
            baton(d, 120, 120, 3.2, 70, 92, 4)
        else:
            baton(d, 120, 120, h * 30, 72, 92, 5)
    # date lens: double ring reads as a cyclops magnifier
    circle(d, 170, 120, 21, outline=WHITE, w=2)
    circle(d, 170, 120, 17, outline=LITE, w=1)
    return img


def bg_reserve():
    """Dress complication dial: Roman numerals, moonphase at 12,
    power-reserve fan at the bottom, date window above 6."""
    img = canvas()
    d = ImageDraw.Draw(img)
    circle(d, 120, 120, 118, outline=LITE, w=1.5)
    for a in range(0, 360, 30):
        r = math.radians(a - 90)
        circle(d, 120 + 104 * math.cos(r), 120 + 104 * math.sin(r), 1.4,
               fill=WHITE)
    # III and IX only: the moonphase owns 12, the reserve fan owns 6
    text(d, 200, 120, 'III', serif_font(24))
    text(d, 40, 120, 'IX', serif_font(24))
    # moonphase sub-dial under 12 (moon image swapped at runtime)
    circle(d, 120, 64, 30, outline=LITE, w=1.5)
    for sx, sy in ((100, 50), (138, 46), (104, 80), (136, 78)):
        circle(d, sx, sy, 1.1, fill=LITE)
    # power reserve: fan-shaped track along the bottom rim (120°..240°)
    arc(d, 120, 120, 100, 120, 240, fill=DARK, w=6)
    for a in (120, 180, 240):
        r = math.radians(a - 90)
        line(d, [120 + 94 * math.cos(r), 120 + 94 * math.sin(r),
                 120 + 106 * math.cos(r), 120 + 106 * math.sin(r)],
             fill=LITE, w=1.5)
    text(d, 194, 162, 'E', serif_font(14), fill=LITE)
    text(d, 46, 162, 'F', serif_font(14), fill=LITE)
    # date window
    d.rounded_rectangle(P(104, 148, 136, 172), radius=3 * SS,
                        outline=LITE, width=int(1.5 * SS))
    return img


def bg_tty():
    """Terminal: scanlines, mono header, prompt chevrons, block cursor."""
    img = canvas()
    d = ImageDraw.Draw(img)
    for y in range(0, 240, 4):
        d.line(P(0, y, 240, y), fill=(50, 50, 50, 255), width=SS)
    text(d, 36, 32, 'moonwatch tty0', mono_font(13), fill=LITE, anchor='lm')
    line(d, [32, 44, 208, 44], fill=LITE, w=1)
    for y in (58, 82, 152, 172, 192):
        text(d, 30, y, '>', mono_font(15), fill=LITE, anchor='lm')
    d.rectangle(P(60, 204, 70, 216), fill=WHITE)
    return img


def bg_radar():
    """Radar scope: range rings, crosshair, bearing ticks, contacts."""
    img = canvas()
    d = ImageDraw.Draw(img)
    for r in (55, 80, 105):
        circle(d, 120, 120, r, outline=DARK, w=1.5)
    line(d, [15, 120, 225, 120], fill=DARK, w=1)
    line(d, [120, 15, 120, 225], fill=DARK, w=1)
    for a in range(0, 360, 30):
        r = math.radians(a - 90)
        line(d, [120 + 101 * math.cos(r), 120 + 101 * math.sin(r),
                 120 + 109 * math.cos(r), 120 + 109 * math.sin(r)],
             fill=LITE, w=1.5)
    for bx, by in ((85, 60), (162, 94), (72, 152)):
        circle(d, bx, by, 2.5, fill=WHITE)
        circle(d, bx, by, 5.5, outline=DARK, w=1)
    return img


INVADER = ['00100000100',
           '00010001000',
           '00111111100',
           '01101110110',
           '11111111111',
           '10111111101',
           '10100000101',
           '00011011000']


def invader(d, cx, cy, s=2, fill=WHITE):
    """Classic pixel alien, s screen-pixels per bit."""
    w, h = len(INVADER[0]), len(INVADER)
    for ry, row in enumerate(INVADER):
        for rx, bit in enumerate(row):
            if bit == '1':
                x = cx - w * s / 2 + rx * s
                y = cy - h * s / 2 + ry * s
                d.rectangle(P(x, y, x + s, y + s), fill=fill)


def fan_scale(d, cx, cy, label):
    """Retrograde fan: 120-degree scale arc above a needle pivot."""
    arc(d, cx, cy, 44, -60, 60, fill=LITE, w=2)
    for a in (-60, -30, 0, 30, 60):
        r = math.radians(a - 90)
        big = a in (-60, 60)
        line(d, [cx + 38 * math.cos(r), cy + 38 * math.sin(r),
                 cx + (50 if big else 46) * math.cos(r),
                 cy + (50 if big else 46) * math.sin(r)],
             fill=WHITE if big else LITE, w=2.5 if big else 1.5)
    circle(d, cx, cy, 4, fill=WHITE)
    text(d, cx, cy + 14, label, label_font(11), fill=LITE)


def bg_retro():
    """Twin retrograde gauges: steps (left) and battery (right)."""
    img = canvas()
    d = ImageDraw.Draw(img)
    fan_scale(d, 66, 130, 'STEP')
    fan_scale(d, 174, 130, 'BATT')
    text(d, 32, 96, '0', label_font(11), fill=LITE)
    text(d, 100, 96, 'G', label_font(11), fill=LITE)
    text(d, 140, 96, 'E', label_font(11), fill=LITE)
    text(d, 208, 96, 'F', label_font(11), fill=LITE)
    ticks(d, 120, 120, 119, n=12, minor_len=0, major_len=6, major_every=1,
          fill=DARK)
    d.rounded_rectangle(P(98, 168, 142, 192), radius=3 * SS,
                        outline=LITE, width=int(1.5 * SS))
    return img


def bg_gnomon():
    """Sundial: stone dial, 24-hour ring (noon up), rotating shadow."""
    img = canvas()
    d = ImageDraw.Draw(img)
    circle(d, 120, 120, 112, outline=LITE, w=1.5)
    circle(d, 120, 120, 96, outline=LITE, w=1.5)
    for i in range(24):
        a = math.radians(i * 15 - 90)
        major = (i % 6) == 0
        line(d, [120 + 97 * math.cos(a), 120 + 97 * math.sin(a),
                 120 + (109 if major else 104) * math.cos(a),
                 120 + (109 if major else 104) * math.sin(a)],
             fill=WHITE if major else DARK, w=2 if major else 1.2)
    text(d, 120, 16, 'XII', serif_font(15))          # noon at the top
    text(d, 22, 120, 'VI', serif_font(14))
    text(d, 214, 120, 'XVIII', serif_font(12))
    # the dial plate the shadow falls on
    circle(d, 120, 120, 88, fill=LITE)
    for i in range(24):
        a = math.radians(i * 15 - 90)
        circle(d, 120 + 80 * math.cos(a), 120 + 80 * math.sin(a),
               1.6 if i % 6 else 2.6, fill=BLACK)
    sun(d, 120, 120 - 45, 8, fill=WHITE)
    return img


def bg_iris():
    """A giant eye: the hands hub disappears inside the pupil."""
    img = canvas()
    d = ImageDraw.Draw(img)
    # iris striations
    for i in range(60):
        a = math.radians(i * 6)
        line(d, [120 + 24 * math.cos(a), 120 + 24 * math.sin(a),
                 120 + 88 * math.cos(a), 120 + 88 * math.sin(a)],
             fill=LITE if i % 2 else DARK, w=1.5)
    circle(d, 120, 120, 90, outline=WHITE, w=2)      # limbus
    circle(d, 120, 120, 60, outline=DARK, w=8)       # iris texture band
    circle(d, 120, 120, 22, fill=BLACK)              # pupil
    circle(d, 120, 120, 22, outline=WHITE, w=1.5)
    # lashes
    for a in (-30, -15, 0, 15, 30):
        r = math.radians(a - 90)
        line(d, [120 + 94 * math.cos(r), 120 + 94 * math.sin(r),
                 120 + 110 * math.cos(r), 120 + 110 * math.sin(r)],
             fill=WHITE, w=3)
    return img


def bg_piet():
    """Mondrian composition; one cell is a masked battery gauge."""
    img = canvas()
    d = ImageDraw.Draw(img)
    circle(d, 120, 120, 118, fill=WHITE)
    # cells (painted before the grid so lines sit on top)
    d.rectangle(P(30, 72, 84, 148), fill=LITE)       # left: steps label
    d.rectangle(P(50, 148, 120, 200), fill=LITE)     # bottom-left: steps
    d.rectangle(P(84, 200, 156, 224), fill=BLACK)    # bottom black slab
    # battery gauge cell: transparent window over an under-drawn solid
    d.rectangle(P(152, 76, 186, 144), fill=CLEAR)
    # grid
    for x0, y0, x1, y1 in ((60, 20, 180, 26), (24, 66, 216, 72),
                           (24, 148, 216, 154), (44, 200, 196, 206),
                           (78, 20, 84, 206), (148, 66, 154, 206),
                           (186, 72, 192, 154), (114, 148, 120, 206)):
        d.rectangle(P(x0, y0, x1, y1), fill=BLACK)
    text(d, 55, 100, 'STEP', label_font(13), fill=BLACK)
    text(d, 170, 62, 'PWR', label_font(12), fill=BLACK)
    text(d, 170, 163, 'KCAL', label_font(12), fill=BLACK)
    return img


def bg_glass():
    """Hourglass: the day drains through it (masked-solid sand)."""
    img = canvas()
    d = ImageDraw.Draw(img)
    # sand windows are punched transparent; solids underneath show through
    d.polygon(P(74, 44, 166, 44, 124, 112, 116, 112), fill=CLEAR)
    d.polygon(P(116, 128, 124, 128, 166, 198, 74, 198), fill=CLEAR)
    # glass outline
    for pts in ([70, 40, 120, 116], [170, 40, 120, 116],
                [120, 124, 70, 200], [120, 124, 170, 200]):
        line(d, pts, fill=WHITE, w=2.5)
    # wooden plates
    for y0, y1 in ((28, 42), (198, 212)):
        d.rounded_rectangle(P(62, y0, 178, y1), radius=4 * SS, fill=LITE)
    return img


def bg_arcade():
    """Space-invaders scoreboard."""
    img = canvas()
    d = ImageDraw.Draw(img)
    text(d, 75, 28, '1UP', mono_font(13), fill=LITE)
    text(d, 160, 28, 'HI', mono_font(13), fill=LITE)
    for y, fill in ((74, WHITE), (96, LITE)):
        for x in range(60, 181, 30):
            invader(d, x, y, 2, fill=fill)
    for x in range(60, 181, 30):
        invader(d, x, 146, 2, fill=DARK)
    # player cannon
    d.polygon(P(112, 196, 128, 196, 120, 186), fill=WHITE)
    d.rectangle(P(104, 196, 136, 202), fill=WHITE)
    heart(d, 96, 214, 10)
    return img


def bg_gazette():
    """A broadsheet front page in white."""
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)
    # sized to clear the round screen edge (chord at y=26 is x 46..194)
    text(d, 120, 32, 'The Daily Moon', serif_font(19), fill=BLACK)
    for y, w in ((44, 2), (47, 1), (60, 1)):
        line(d, [22, y, 218, y], fill=BLACK, w=w)
    # two print columns of pretend body text; the gap hosts the hub
    for col_x0, col_x1 in ((26, 104), (136, 214)):
        for i, y in enumerate(range(110, 159, 7)):
            frac = 1.0 if i % 4 else 0.7
            line(d, [col_x0, y, col_x0 + (col_x1 - col_x0) * frac, y],
                 fill=LITE, w=1)
    # inset boxes: weather and power (kept inside the round screen)
    for x0, label in ((34, 'WEATHER'), (134, 'POWER')):
        d.rectangle(P(x0, 160, x0 + 72, 200), outline=BLACK,
                    width=int(1.2 * SS))
        text(d, x0 + 36, 168, label, serif_font(10), fill=BLACK)
    return img


def dashed_circle(d, cx, cy, r, fill, w, n=16):
    for i in range(n):
        a0 = i * (360 / n)
        arc(d, cx, cy, r, a0, a0 + 360 / n * 0.6, fill=fill, w=w)


def bg_schema():
    """An engineering drawing of the watch itself."""
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)
    for x0, y0, x1, y1, w in ((14, 14, 226, 226, 2), (20, 20, 220, 220, 1)):
        d.rectangle(P(x0, y0, x1, y1), outline=BLACK, width=int(w * SS))
    # the subject: our own case, with center mark on the hands hub
    circle(d, 120, 120, 34, outline=BLACK, w=2)
    dashed_circle(d, 120, 120, 24, BLACK, 1)
    line(d, [98, 120, 142, 120], fill=BLACK, w=1)
    line(d, [120, 98, 120, 142], fill=BLACK, w=1)
    # dimension: leader from the circle up to a note
    line(d, [144, 96, 186, 54], fill=BLACK, w=1)
    line(d, [186, 54, 204, 54], fill=BLACK, w=1)
    text(d, 195, 44, 'R34', mono_font(10), fill=BLACK)
    text(d, 48, 48, 'A', mono_font(12), fill=BLACK)
    d.polygon(P(40, 58, 56, 58, 48, 44), outline=BLACK, width=int(1 * SS))
    text(d, 64, 196, 'SCALE 1:1', mono_font(9), fill=BLACK)
    # title block, clear of the drawing
    d.rectangle(P(114, 154, 194, 206), outline=BLACK, width=int(1.5 * SS))
    for y in (171, 188):
        line(d, [114, y, 194, y], fill=BLACK, w=1)
    line(d, [148, 154, 148, 206], fill=BLACK, w=1)
    for y, label in ((163, 'DATE'), (180, 'STEP'), (197, 'PWR')):
        text(d, 131, y, label, mono_font(9), fill=BLACK)
    return img


def bg_transit():
    """A metro map; every line departs the hub interchange."""
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)
    lines = [
        ([120, 105, 120, 72, 146, 46, 168, 46], BLACK, [(120, 88), (133, 59)]),
        ([135, 120, 168, 120, 190, 142], DARK, [(152, 120), (179, 131)]),
        ([120, 135, 120, 166, 94, 192, 80, 192], BLACK, [(120, 151), (107, 179)]),
        ([105, 120, 74, 120, 52, 98, 52, 88], DARK, [(90, 120), (63, 109)]),
    ]
    for pts, fill, stations in lines:
        line(d, pts, fill=fill, w=5)
        for sx, sy in stations:
            circle(d, sx, sy, 3.4, fill=WHITE, outline=BLACK, w=1.6)
    # terminal boxes hold the runtime values
    for x0, y0, label, lx, ly in ((144, 36, 'STEP', 148, 28),
                                  (162, 132, 'KCAL', 190, 160),
                                  (40, 182, 'BPM', 68, 210),
                                  (24, 66, 'BATT', 52, 58)):
        d.rounded_rectangle(P(x0, y0, x0 + 56, y0 + 20), radius=5 * SS,
                            outline=BLACK, width=int(1.6 * SS))
        text(d, lx, ly, label, label_font(11), fill=DARK)
    # interchange ring around the hands hub
    circle(d, 120, 120, 15, outline=BLACK, w=2.5)
    return img


def bg_calc():
    """A pocket calculator; the hub is the round OFF button."""
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)
    d.rectangle(P(34, 36, 206, 88), fill=LITE, outline=BLACK,
                width=int(2 * SS))
    keys = [('7', 52, 104), ('8', 94, 104), ('9', 146, 104), ('C', 188, 104),
            ('4', 52, 140), ('5', 94, 140), ('6', 146, 140), ('÷', 188, 140),
            ('1', 52, 176), ('2', 94, 176), ('3', 146, 176), ('×', 188, 176),
            ('0', 94, 208), ('=', 146, 208)]
    for label, cx, cy in keys:
        d.rounded_rectangle(P(cx - 15, cy - 12, cx + 15, cy + 12),
                            radius=4 * SS, outline=BLACK,
                            width=int(1.6 * SS))
        text(d, cx, cy, label, mono_font(13), fill=BLACK)
    circle(d, 120, 120, 13, fill=DARK)      # OFF button = hands hub
    return img


def bg_todo():
    """A notepad of daily goals."""
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)
    for x in range(30, 211, 18):
        circle(d, x, 16, 4, outline=BLACK, w=1.6)
    line(d, [16, 28, 224, 28], fill=LITE, w=1)
    text(d, 120, 44, 'TODAY', marker_font(20), fill=BLACK)
    line(d, [88, 56, 152, 57], fill=BLACK, w=2)
    for label, y in (('walk', 66), ('burn 400', 96),
                     ('move 30m', 156), ('charge me', 186)):
        text(d, 52, y, label, marker_font(16), fill=BLACK, anchor='lm')
        line(d, [24, y + 12, 216, y + 12], fill=LITE, w=1)
    text(d, 120, 214, 'wind watch', marker_font(15), fill=BLACK)
    line(d, [88, 214, 152, 213], fill=DARK, w=1.6)
    return img


def pol(cx, cy, r, a):
    """Point at radius r, angle a (watch convention: 0 = up, cw)."""
    t = math.radians(a - 90)
    return cx + r * math.cos(t), cy + r * math.sin(t)


def stamp(img, cx, cy, s, font, fill=BLACK, angle=0.0):
    """Draw string s centred at screen (cx, cy) on the supersampled img,
    rotated `angle` degrees clockwise (0 = upright)."""
    pad = 70 * SS
    tmp = Image.new('RGBA', (pad * 2, pad * 2), CLEAR)
    ImageDraw.Draw(tmp).text((pad, pad), s, font=font, fill=fill, anchor='mm')
    tmp = tmp.rotate(-angle, resample=Image.BICUBIC, center=(pad, pad))
    img.alpha_composite(tmp, (int(round(cx * SS)) - pad,
                              int(round(cy * SS)) - pad))


def bg_grande():
    """Grande Complication: eight analog sub-dials around the physical
    hands, moonphase aperture at 12, calorie and power-reserve gauges
    on the rim.  Ref. 57260 spirit, Hybrid HR data."""
    img = canvas()
    d = ImageDraw.Draw(img)

    def tick(cx, cy, a, r0, r1, w=1.2, fill=WHITE):
        x0, y0 = pol(cx, cy, r0, a)
        x1, y1 = pol(cx, cy, r1, a)
        line(d, [x0, y0, x1, y1], fill=fill, w=w)

    # bezel ticks, skipping the two rim-gauge sectors
    for i in range(12):
        a = i * 30
        if 30 <= a <= 90 or 210 <= a <= 270:
            continue
        tick(120, 120, a, 112, 118, w=1.5, fill=LITE)

    # rim gauges: calories upper-right, power reserve lower-left
    for a0, label in ((30, 'KCAL'), (210, 'RES')):
        arc(d, 120, 120, 116, a0, a0 + 60, fill=DARK, w=3)
        for a in (a0, a0 + 60):
            tick(120, 120, a, 111, 120, w=1.5)
        lx, ly = pol(120, 120, 104, a0 + 30)
        text(d, lx, ly, label, label_font(8), fill=LITE)

    # guilloche rings around the hands hub
    for r in (18, 24, 30):
        circle(d, 120, 120, r, outline=DARK, w=1)

    D = 68          # sub-dial orbit

    def dial(ang):
        cx, cy = pol(120, 120, D, ang)
        circle(d, cx, cy, 24, outline=LITE, w=1.5)
        circle(d, cx, cy, 2.2, fill=WHITE)
        return cx, cy

    def gauge(ang, n, lo, hi, glyph, label):
        """300-degree instrument scale with a rest gap at the bottom."""
        cx, cy = dial(ang)
        arc(d, cx, cy, 21, -150, 150, fill=DARK, w=2)
        for k in range(n):
            tick(cx, cy, -150 + k * 300 / (n - 1), 19, 23)
        for s, a in ((lo, -150), (hi, 150)):
            tx, ty = pol(cx, cy, 13, a)
            text(d, tx, ty, s, label_font(7), fill=LITE)
        glyph(d, cx, cy - 8, 6)
        text(d, cx, cy + 13, label, label_font(8), fill=LITE)

    # 12:00 — moonphase aperture (disc image swapped at runtime)
    cx, cy = pol(120, 120, D, 0)
    circle(d, cx, cy, 24, outline=LITE, w=1.5)
    text(d, 120, 80, 'LUNE', label_font(8), fill=LITE)

    # 1:30 — weekday
    cx, cy = dial(45)
    for i, ch in enumerate('SMTWTFS'):
        a = i * 360 / 7
        tick(cx, cy, a, 19, 22)
        tx, ty = pol(cx, cy, 15, a)
        text(d, tx, ty, ch, label_font(8), fill=LITE)
    text(d, cx, cy + 8, 'JOUR', label_font(7), fill=DARK)

    # 3:00 — analog date, 1..31
    cx, cy = dial(90)
    for i in range(31):
        a = i * 360 / 31
        major = i in (0, 7, 14, 22)
        tick(cx, cy, a, 20 if major else 21.5, 23,
             w=1.4 if major else 0.8, fill=WHITE if major else LITE)
    for s, i in (('1', 0), ('8', 7), ('15', 14), ('23', 22)):
        tx, ty = pol(cx, cy, 14, i * 360 / 31)
        text(d, tx, ty, s, label_font(8), fill=LITE)
    text(d, cx, cy + 8, 'DATE', label_font(7), fill=DARK)

    # 4:30 — heart rate, 40..140
    gauge(135, 6, '40', '140', heart, 'PULS')

    # 6:00 — 24 hours, noon up
    cx, cy = dial(180)
    for i in range(24):
        tick(cx, cy, i * 15, 20 if i % 6 == 0 else 21.5, 23,
             w=1.4 if i % 6 == 0 else 0.8)
    sun(d, cx, cy - 12, 5)
    moon(d, cx, cy + 12, 4)

    # 7:30 — active minutes 0..60
    gauge(225, 7, '0', '60', bolt, 'ACT')

    # 9:00 — steps 0..10k
    gauge(270, 6, '0', '10K', shoe, 'PAS')

    # 10:30 — month
    cx, cy = dial(315)
    for i in range(12):
        tick(cx, cy, i * 30, 19 if i % 3 == 0 else 21, 23,
             w=1.4 if i % 3 == 0 else 0.9)
    for s in ('1', '4', '7', '10'):
        tx, ty = pol(cx, cy, 14, (int(s) - 1) * 30)
        text(d, tx, ty, s, label_font(8), fill=LITE)
    text(d, cx, cy + 8, 'MOIS', label_font(7), fill=DARK)

    return img


def bg_grande2():
    """Grande II: a large calendar dial with the moonphase at its
    heart and orbiting date/weekday dots, big steps+active and pulse
    dials, a month fan, calorie and reserve gauges on the rim."""
    img = canvas()
    d = ImageDraw.Draw(img)

    def tick(cx, cy, a, r0, r1, w=1.2, fill=WHITE):
        x0, y0 = pol(cx, cy, r0, a)
        x1, y1 = pol(cx, cy, r1, a)
        line(d, [x0, y0, x1, y1], fill=fill, w=w)

    # bezel ticks, sparing the three rim-gauge sectors
    for i in range(12):
        a = i * 30
        if 30 <= a <= 150 or 210 <= a <= 270:
            continue
        tick(120, 120, a, 112, 118, w=1.5, fill=LITE)

    # rim gauges: calories upper-right, rain chance right, power
    # reserve lower-left
    arc(d, 120, 120, 116, 30, 90, fill=DARK, w=4)
    for a in (30, 90):
        tick(120, 120, a, 110, 120, w=1.8)
    text(d, 190, 43, 'KCAL', label_font(12), fill=LITE)
    arc(d, 120, 120, 116, 90, 150, fill=DARK, w=4)
    tick(120, 120, 150, 110, 120, w=1.8)
    # the steps dial crowds this sector: the label sits at its far
    # end, the way RES labels its own sector from the 210 side
    text(d, 176, 208, 'PLUIE', label_font(12), fill=LITE)
    arc(d, 120, 120, 116, 210, 270, fill=DARK, w=4)
    for a in (210, 270):
        tick(120, 120, a, 110, 120, w=1.8)
    text(d, 46, 195, 'RES', label_font(12), fill=LITE)

    # guilloche around the hands hub
    for r in (18, 23):
        circle(d, 120, 120, r, outline=DARK, w=1)

    # ---- the calendar: moon at heart, date + weekday dot orbits ---
    cx, cy = 120, 58
    circle(d, cx, cy, 49, outline=LITE, w=2)
    for i in range(31):
        major = i in (0, 7, 14, 22)
        tick(cx, cy, i * 360 / 31, 44 if major else 46.5, 49,
             w=1.6 if major else 0.8, fill=WHITE if major else LITE)
    for s, i in (('1', 0), ('8', 7), ('15', 14), ('23', 22)):
        tx, ty = pol(cx, cy, 36, i * 360 / 31)
        text(d, tx, ty, s, label_font(12), fill=WHITE)
    for i, ch in enumerate('SMTWTFS'):
        tx, ty = pol(cx, cy, 22, i * 360 / 7)
        text(d, tx, ty, ch, label_font(11), fill=LITE)

    # ---- right: steps (long) + active minutes (short) ------------
    cx, cy = 182, 150
    circle(d, cx, cy, 42, outline=LITE, w=2)
    circle(d, cx, cy, 2.6, fill=WHITE)
    arc(d, cx, cy, 38, -150, 150, fill=DARK, w=2)
    for k in range(6):
        tick(cx, cy, -150 + k * 60, 35, 40, w=1.6)
    for s, a in (('0', -150), ('5', 0), ('10K', 150)):
        tx, ty = pol(cx, cy, 30, a)
        text(d, tx, ty, s, label_font(11), fill=WHITE)
    for k in range(7):
        tick(cx, cy, -150 + k * 50, 16, 19, w=1.0, fill=LITE)
    shoe(d, cx, cy - 13, 6)
    text(d, cx, cy + 12, 'PAS·ACT', label_font(12), fill=LITE)

    # ---- left: heart rate ----------------------------------------
    cx, cy = 58, 150
    circle(d, cx, cy, 36, outline=LITE, w=2)
    circle(d, cx, cy, 2.6, fill=WHITE)
    arc(d, cx, cy, 32, -150, 150, fill=DARK, w=2)
    for k in range(6):
        tick(cx, cy, -150 + k * 60, 29, 34, w=1.5)
    for s, a in (('40', -150), ('90', 0), ('140', 150)):
        tx, ty = pol(cx, cy, 23, a)
        text(d, tx, ty, s, label_font(10), fill=WHITE)
    heart(d, cx, cy - 10, 5)
    text(d, cx, cy + 8, 'PULS', label_font(12), fill=LITE)

    # ---- upper corners: temperature and UV ------------------------
    def mini(cx, cy, lo, hi, label):
        """Small 300-degree instrument, rest gap at the bottom.  Too
        small for a glyph as well: the name goes above the hub, the
        scale ends sit in the gap the arc leaves at the bottom."""
        circle(d, cx, cy, 21, outline=LITE, w=1.5)
        arc(d, cx, cy, 18, -150, 150, fill=DARK, w=2)
        for k in range(6):
            tick(cx, cy, -150 + k * 60, 15, 19, w=1.4)
        text(d, cx, cy - 11, label, label_font(11), fill=LITE)
        for s, a in ((lo, -150), (hi, 150)):
            tx, ty = pol(cx, cy, 12, a)
            text(d, tx, ty, s, label_font(8), fill=WHITE)
        circle(d, cx, cy, 2.2, fill=WHITE)

    mini(46, 82, '-10', '40', 'TEMP')
    mini(194, 82, '0', '11', 'UV')

    # ---- bottom: month fan ---------------------------------------
    cx, cy = 120, 202
    arc(d, cx, cy, 18, -60, 60, fill=DARK, w=2)
    for k in range(12):
        tick(cx, cy, -60 + k * 120 / 11, 15, 20, w=1.2)
    for s, a in (('1', -60), ('12', 60)):
        tx, ty = pol(cx, cy, 11, a)
        text(d, tx, ty, s, label_font(8), fill=WHITE)
    circle(d, cx, cy, 2.2, fill=WHITE)
    text(d, cx, cy + 13, 'MOIS', label_font(11), fill=LITE)

    return img


def bg_horizon():
    """Horizon: one day as a ring cut by the horizon line — daylight
    over the top (sunrise at 9 o'clock, noon at 12, sunset at 3),
    night under the bottom.  The orb and the spent-daylight arc are
    drawn at runtime."""
    img = canvas()
    d = ImageDraw.Draw(img)
    R = 88

    # the ring: bright where the sun is up, dim where it is down
    arc(d, 120, 120, R, 270, 450, fill=DARK, w=3)
    for a0 in range(90, 270, 12):       # night half, dashed
        arc(d, 120, 120, R, a0, a0 + 7, fill=DARK, w=1.5)

    # the horizon itself, broken around the hands hub
    for x0, x1 in ((26, 100), (140, 214)):
        line(d, [x0, 120, x1, 120], fill=DARK, w=1)

    # rise/set gates, solar noon and midnight
    for a in (90, 270):
        x0, y0 = pol(120, 120, R - 8, a)
        x1, y1 = pol(120, 120, R + 8, a)
        line(d, [x0, y0, x1, y1], fill=LITE, w=1.6)
    sun(d, 120, 14, 8, fill=DARK)
    moon(d, 120, 227, 7, fill=DARK)

    # what the two clock times under the horizon are
    text(d, 71, 132, 'RISE', label_font(10), fill=LITE)
    text(d, 169, 132, 'SET', label_font(10), fill=LITE)

    return img


def render_orb(kind):
    """18x18 sun or moon token that rides the Horizon ring."""
    img = Image.new('RGBA', (18 * SS, 18 * SS), CLEAR)
    d = ImageDraw.Draw(img)
    if kind == 'sunorb':
        sun(d, 9, 9, 15)
    else:
        # crescent: a bright disc with a black disc slid off it, then
        # outlined so it still reads against the black screen
        circle(d, 9, 9, 7, fill=WHITE)
        circle(d, 12.5, 7.5, 6.5, fill=CLEAR)
        circle(d, 9, 9, 7, outline=LITE, w=1)
    return img


def bg_almanac():
    """Almanac: a Monday-to-Sunday strip under its weekday letters,
    room for the week number and the day count, and a rim gauge for
    the year with a tick where each month starts."""
    img = canvas()
    d = ImageDraw.Draw(img)
    cols = [33, 62, 91, 120, 149, 178, 207]

    # the year track, ticked at the first of each month (common year)
    circle(d, 120, 120, 112, outline=DARK, w=4)
    starts = (0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334)
    for k, doy in enumerate(starts):
        a = doy / 365 * 360
        quarter = (k % 3) == 0
        x0, y0 = pol(120, 120, 106 if quarter else 108, a)
        x1, y1 = pol(120, 120, 118, a)
        line(d, [x0, y0, x1, y1], fill=LITE if quarter else DARK,
             w=1.6 if quarter else 1.1)

    # weekday letters over the strip, weekend in a dimmer grey
    for i, ch in enumerate('MTWTFSS'):
        text(d, cols[i], 65, ch, label_font(13),
             fill=WHITE if i >= 5 else LITE)
    line(d, [22, 110, 218, 110], fill=DARK, w=1)

    return img


def render_mark():
    """26x30 box drawn around today's column in the Almanac strip."""
    img = Image.new('RGBA', (26 * SS, 30 * SS), CLEAR)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(P(1, 1, 25, 29), radius=4 * SS,
                        outline=LITE, width=int(1.6 * SS))
    return img


def globe(d, cx, cy, r, fill=DARK):
    """Wire globe: outline, equator and two meridians."""
    circle(d, cx, cy, r, outline=fill, w=1.2)
    d.ellipse(P(cx - r, cy - r * 0.34, cx + r, cy + r * 0.34),
              outline=fill, width=int(1.2 * SS))
    for k in (0.42, 1.0):
        d.ellipse(P(cx - r * k, cy - r, cx + r * k, cy + r),
                  outline=fill, width=int(1.2 * SS))


def bg_meridian():
    """Meridian: a world-timer sheet — local time and date over three
    ruled zone rows.  Everything else is filled in at runtime."""
    img = canvas()
    d = ImageDraw.Draw(img)

    globe(d, 120, 20, 11)

    # rule under the local clock, then one between each pair of zone
    # rows (absolute text hangs off its baseline, so the rows sit
    # above their layout 'top' — these fall in the gaps)
    line(d, [44, 100, 196, 100], fill=LITE, w=1)
    for y in (161, 183):
        line(d, [44, y, 196, y], fill=DARK, w=1)

    return img


def render_daynight(kind):
    """14x14 sun/moon token for the Meridian rows (or an empty slot)."""
    img = Image.new('RGBA', (14 * SS, 14 * SS), CLEAR)
    d = ImageDraw.Draw(img)
    if kind == 'dsun':
        sun(d, 7, 7, 12)
    elif kind == 'dmoon':
        circle(d, 7, 7, 5.5, fill=WHITE)
        circle(d, 10, 4.5, 5, fill=CLEAR)
    return img


# ============================================== final elegant set
# split/stack/type + rayon/deco/aria/ivory (bigger numerals) + seigaiha.


def _plate(d, x0, y0, x1, y1, r=6, outline=LITE):
    d.rectangle(P(x0, y0, x1, y1), fill=BLACK)
    d.rounded_rectangle(P(x0, y0, x1, y1), radius=r * SS,
                        outline=outline, width=int(1.4 * SS))


def bg_split():
    img = canvas()
    d = ImageDraw.Draw(img)
    d.polygon(P(240, 0, 240, 240, 0, 240), fill=WHITE)
    line(d, [240, 0, 0, 240], fill=DARK, w=2)
    return img


def bg_stack():
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)
    circle(d, 120, 120, 118, fill=WHITE)
    text(d, 46, 40, 'ACTIVITY', label_font(15), fill=LITE, anchor='ls')
    for y, lab in ((80, 'STEPS'), (152, 'ACTIVE'), (184, 'BATT')):
        text(d, 46, y, lab, label_font(13), fill=BLACK, anchor='ls')
    for y in (86, 158, 190):
        d.rectangle(P(46, y, 196, y + 14), fill=LITE)
    return img


def bg_type():
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)
    circle(d, 120, 120, 118, fill=WHITE)
    line(d, [28, 118, 212, 118], fill=BLACK, w=5)
    for x in (28, 212):
        line(d, [x, 110, x, 126], fill=BLACK, w=5)
    return img


def bg_rayon():
    img = canvas()
    d = ImageDraw.Draw(img)
    for k, a in enumerate(range(0, 360, 10)):
        x0, y0 = pol(120, 120, 14, a)
        x1, y1 = pol(120, 120, 110, a)
        line(d, [x0, y0, x1, y1], fill=(LITE if k % 2 == 0 else DARK),
             w=(1.6 if k % 2 == 0 else 1))
    circle(d, 120, 120, 110, outline=LITE, w=2)
    circle(d, 120, 120, 100, outline=DARK, w=1)
    for h in range(12):
        a = h * 30
        xo, yo = pol(120, 120, 106, a)
        xi, yi = pol(120, 120, 92, a)
        line(d, [xi, yi, xo, yo], fill=LITE, w=(4 if h % 3 == 0 else 2))
    text(d, 120, 40, 'STEPS', serif_font(11), fill=LITE)
    _plate(d, 82, 48, 158, 74, r=5)
    _plate(d, 58, 154, 182, 192, r=7)
    return img


def bg_deco():
    img = canvas()
    d = ImageDraw.Draw(img)
    for a in range(-54, 55, 9):
        x, y = pol(120, 20, 112, a)
        line(d, [120, 20, x, y], fill=WHITE, w=2)
    d.rectangle(P(0, 96, 240, 240), fill=BLACK)
    arc(d, 120, 20, 78, -52, 52, fill=WHITE, w=2)
    line(d, [20, 98, 220, 98], fill=WHITE, w=2)
    for sx in (44, 196):
        for i in range(3):
            hw = 18 - i * 5
            d.rectangle(P(sx - hw, 206 + i * 6, sx + hw, 210 + i * 6),
                        fill=WHITE)
    d.polygon(P(120, 130, 190, 159, 120, 188, 50, 159),
              outline=WHITE, width=int(2 * SS))
    _plate(d, 78, 48, 162, 74, r=5, outline=WHITE)
    _plate(d, 62, 142, 178, 176, r=6, outline=WHITE)
    _plate(d, 86, 196, 154, 220, r=5, outline=WHITE)
    return img


def bg_aria():
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)
    circle(d, 120, 120, 118, fill=WHITE)
    circle(d, 120, 120, 100, outline=LITE, w=1)
    circle(d, 120, 120, 84, outline=LITE, w=1)
    ticks(d, 120, 120, 112, n=12, minor_len=0, major_len=6, major_every=1,
          major_w=1.4, fill=DARK)

    text(d, 165, 98, 'STEPS', serif_font_bold(16), fill=DARK, anchor='mm')
    text(d, 70, 98, 'BATT', serif_font_bold(16), fill=DARK, anchor='mm')
    return img


def bg_ivory():
    """Porcelain dial, railroad track, full ring of large serif numerals."""
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)
    circle(d, 120, 120, 118, fill=WHITE)
    circle(d, 120, 120, 112, outline=BLACK, w=1.2)
    circle(d, 120, 120, 106, outline=BLACK, w=0.8)
    for i in range(60):
        a = i * 6
        xo, yo = pol(120, 120, 112, a)
        xi, yi = pol(120, 120, 106, a)
        line(d, [xi, yi, xo, yo], fill=(BLACK if i % 5 == 0 else DARK),
             w=(1.4 if i % 5 == 0 else 0.7))
    for h in range(1, 13):
        a = h * 30
        x, y = pol(120, 120, 80, a)
        text(d, x, y, str(h), serif_font(30), fill=BLACK)
    d.rounded_rectangle(P(82, 150, 158, 176), radius=3 * SS,
                        outline=BLACK, width=int(1.2 * SS))
    return img


def bg_seigaiha():
    """The Japanese seigaiha (wave-scallop) pattern, banded in grey."""
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)
    R = 40
    bands = [(R, DARK), (R - 4, WHITE), (R - 9, LITE), (R - 13, WHITE),
             (R - 18, DARK), (R - 22, WHITE), (R - 27, LITE), (R - 32, WHITE), (R - 32, DARK)]

    row_h = 18
    step = 1.8 * (R**2 - row_h**2) ** 0.5
    
    row = 0
    y = -R
    while y < 240 + R:
        xoff = step / 2.0 + step/2.0 if row % 2 else step/2.0
        x = -R
        while x < 240 + R:
            for rr, fl in bands:
                circle(d, x + xoff, y, rr, fill=fl)
            x += step
        y += row_h
        row += 1

    veil = Image.new('RGBA', img.size, (0, 0, 0, 0))
    vd = ImageDraw.Draw(veil)

    
    # Numerals
    nums = [3, 6, 9, 12]
    for h in nums:
        a = h * 30
        x, y = pol(120, 120, 100, a)
        circle(vd, x, y, 25, outline=DARK, fill=TRANSLUCENT, w=2)
        
    img.alpha_composite(veil)
    for h in nums:
        a = h * 30
        x, y = pol(120, 120, 100, a)
        text(d, x, y, str(h), serif_font_bold(45), fill=BLACK)
    
    # Subdue (don't punch out) the pattern under the text windows: composite
    # a semi-opaque white veil over the scallops so they still read, faintly,
    # behind the black text. The watch can't blend a transparent background
    # window against anything (there's only blank framebuffer behind the
    # image), so the dimming has to be baked in here with real alpha
    # compositing — d.rectangle would just *replace* pixels. Raise
    # TRANSLUCENT's alpha toward 255 for a lighter panel, lower it to show
    # more pattern.
    windows = ((120-40, 144, 120+40, 174), (84, 177, 156, 200))  # date, steps
    veil = Image.new('RGBA', img.size, (0, 0, 0, 0))
    vd = ImageDraw.Draw(veil)
    for x0, y0, x1, y1 in windows:
        vd.rounded_rectangle(P(x0, y0, x1, y1), radius=6 * SS,
                             fill=TRANSLUCENT)
    img.alpha_composite(veil)
    for x0, y0, x1, y1 in windows:
        d.rounded_rectangle(P(x0, y0, x1, y1), radius=6 * SS,
                            outline=DARK, width=int(1.4 * SS))
    # night-sky disc behind the moon complication: a black circle wider than
    # the 36 px moon sprite, sprinkled with stars. The moon sprite (r15) draws
    # over the middle at runtime; its transparent corners show the sky. Nudged
    # up (center y58) so the larger disc stays clear of the hands hub.
    mx, my, mr = 120, 58, 38
    circle(d, mx, my, mr, fill=BLACK)
    stars = [(100, 42, 1.5), (140, 44, 1.2), (94, 62, 1.3), (146, 66, 1.6),
             (104, 84, 1.2), (136, 86, 1.4), (120, 26, 1.1), (120, 90, 1.2)]
    for sx, sy, sr in stars:
        circle(d, sx, sy, sr, fill=WHITE)
    # a couple of twinkles (little cross sparkles)
    for sx, sy in ((146, 66), (100, 42)):
        line(d, [sx - 3, sy, sx + 3, sy], fill=WHITE, w=0.8)
        line(d, [sx, sy - 3, sx, sy + 3], fill=WHITE, w=0.8)
    circle(d, mx, my, mr, outline=DARK, w=1.4)
    return img


def bg_argyle():
    """A knitted argyle field: two-tone diamonds under dotted intercross
    lines, with four veiled cartouches for steps/BPM/battery/date."""
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)

    a, b = 26, 34  # diamond half-width / half-height
    # Two interleaved lattices tile the plane. The B-lattice cells stay white;
    # the A-lattice diamonds checker between dark and light grey — a classic
    # three-tone argyle knit.
    y = -b
    j = 0
    while y < 240 + b:
        x = -a + (a if j % 2 else 0)
        i = 0
        while x < 240 + a:
            fl = DARK if (i + j) % 2 else LITE
            d.polygon(P(x - a, y, x, y - b, x + a, y, x, y + b), fill=fl)
            x += 2 * a
            i += 1
        y += b
        j += 1

    # Dotted intercross lines running through the diamond centres, both
    # diagonals, in a darker knit thread.
    def dotted(x0, y0, x1, y1, gap=7, r=1.0, fill=DARK):
        dist = math.hypot(x1 - x0, y1 - y0)
        n = max(1, int(dist / gap))
        for i in range(n + 1):
            t = i / float(n)
            circle(d, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, r, fill=fill)

    for k in range(-14, 24, 2):
        y0, y1 = -b, 240 + b
        dotted(a * (k + y0 / float(b)), y0, a * (k + y1 / float(b)), y1)
        dotted(a * (k - y0 / float(b)), y0, a * (k - y1 / float(b)), y1)

    # Thin bezel to frame the knit.
    circle(d, 120, 120, 117, outline=DARK, w=2)

    # Four cartouches. Subdue (don't punch out) the pattern under each with a
    # baked translucent veil so the diamonds still read faintly behind the
    # black text — the watch can't blend a window against blank framebuffer,
    # so the dimming is composited here with real alpha (see bg_seigaiha).
    windows = ((86, 40, 172, 70),      # steps (top)
               (30, 108, 102, 138),    # bpm (left)
               (140, 108, 216, 138),   # battery (right)
               (72, 182, 168, 208))    # date (bottom)
    veil = Image.new('RGBA', img.size, (0, 0, 0, 0))
    vd = ImageDraw.Draw(veil)
    for x0, y0, x1, y1 in windows:
        vd.rounded_rectangle(P(x0, y0, x1, y1), radius=7 * SS,
                             fill=TRANSLUCENT)
    img.alpha_composite(veil)
    for x0, y0, x1, y1 in windows:
        d.rounded_rectangle(P(x0, y0, x1, y1), radius=7 * SS,
                            outline=DARK, width=int(1.4 * SS))

    # Baked label glyphs (the value text is placed to the right of each).
    shoe(d, 99, 55, 15, fill=BLACK)
    heart(d, 44, 121, 15, fill=BLACK)
    battery(d, 151, 121, 16, fill=BLACK)
    return img


# --- Escher lizard: a p3 (wallpaper) tiling built the proper way ----------
# A regular hexagon whose three "free" edges each determine the neighbouring
# edge by a 120-degree rotation about the shared corner (Heesch type CCC).
# Whatever shape the free edges take, the tile fits around every corner with
# no gaps -- so we can carve a splayed six-limbed lizard and know it tiles.

def _aff_rot(deg, px, py):
    """Affine (a,b,c,d,e,f) for rotation by deg about (px,py). y is up."""
    t = math.radians(deg)
    ct, st = math.cos(t), math.sin(t)
    return (ct, -st, st, ct,
            px - ct * px + st * py,
            py - st * px - ct * py)


def _aff_apply(M, x, y):
    return (M[0] * x + M[1] * y + M[4], M[2] * x + M[3] * y + M[5])


def _aff_compose(R, M):
    """R after M."""
    a1, b1, c1, d1, e1, f1 = R
    a2, b2, c2, d2, e2, f2 = M
    return (a1 * a2 + b1 * c2, a1 * b2 + b1 * d2,
            c1 * a2 + d1 * c2, c1 * b2 + d1 * d2,
            a1 * e2 + b1 * f2 + e1, c1 * e2 + d1 * f2 + f1)


def _aff_inv(M):
    a, b, c, d, e, f = M
    det = a * d - b * c
    ia, ib, ic, id_ = d / det, -b / det, -c / det, a / det
    return (ia, ib, ic, id_, -(ia * e + ib * f), -(ic * e + id_ * f))


def _aff_fixed_point(M):
    """Centre of a rotation affine: solve (I - linear) x = translation."""
    a, b, c, d, e, f = M
    det = (1 - a) * (1 - d) - (-b) * (-c)
    return (((1 - d) * e - (-b) * f) / det,
            ((1 - a) * f - (-c) * e) / det)


# One Escher reptile as an SVG outline (48-vertex polygon, y-down like SVG).
# It tiles the plane by p3 symmetry: three-fold rotations about three of its
# limb tips. Indices 1 (a forefoot), 19 (a hind foot) and 34 (a hind foot) are
# the order-3 rotation centres -- found by testing which vertices, rotated
# 120 deg, drop an exact edge-adjacent copy of the tile with no overlap.
_REPTILE_PATH = (
    "81.158749,56.384209 29.071261,8.248419 7.55598,29.439232 8.68937,3.283939"
    " 20.8661,-9.386842 2.90615,-27.782729 7.93377,0.784659 10.69461,15.867541"
    " -3.51644,7.381605 -8.48593,0.63935 -1.77275,17.465927 -28.30584,9.99713"
    " -9.38684,24.96377 14.64696,-14.2401 20.63362,-1.62744 9.27059,4.35921"
    " 4.35922,17.29156 9.18341,4.41733 -1.88899,18.04715 -20.1977,-5.52167"
    " -5.14387,-20.66268 -17.66935,7.90471 0.78466,10.37493 -12.72891,12.38017"
    " 0.78466,10.28775 11.74082,16.79751 17.20437,4.76607 -23.22009,3.89423"
    " -22.20293,-18.62837 -8.747494,-18.65744 -28.945189,-7.84659"
    " -12.292986,26.32966 -16.942816,-7.78847 6.684132,-5.08575"
    " 7.178172,-23.80131 24.353483,-5.43449 8.54406,3.48737 -1.59838,-19.84896"
    " -29.875151,2.32492 -7.875649,-28.68363 11.798943,-16.913758"
    " 13.833242,9.706517 -3.429251,7.555971 4.882322,7.03287 19.383975,-1.42401"
    " 5.085752,-7.17818 -22.551673,-16.100028 1.947116,-22.609797")
# The 48-vertex path has six corners (indices 1,10,19,28,34,40): the three
# rotation centres 1/19/34 alternate with the plain corners 10/28/40, so its
# six edges pair up (e0-e5, e1-e2, e3-e4) by a 120-deg rotation about the
# centre between them. The hand-drawn path only tessellates approximately, so
# we REBUILD it exactly: keep three master edges and regenerate their partners
# as exact rotations. The third centre is derived from the group relation
# a*b*c = 1 (c = (a*b)^-1) so the tile closes perfectly and tiles gap-free
# under the two generators a, b alone.
_REPTILE_VERTS = (1, 10, 19, 28, 34, 40)


def _reptile_tile(scale):
    """Return (poly, (A, B), eye) for one lizard in screen units, centred on the
    origin: the exact tessellating outline and the two p3 rotation centres that
    generate the tiling. `scale` maps SVG-path units to pixels."""
    toks = _REPTILE_PATH.replace(",", " ").split()
    pts = []
    cx = cy = 0.0
    for i in range(0, len(toks), 2):
        dx, dy = float(toks[i]), float(toks[i + 1])
        if not pts:
            cx, cy = dx, dy                       # first pair is absolute
        else:
            cx += dx
            cy += dy                              # rest are relative lineto
        pts.append((cx, cy))

    def arc(i, j):
        out, k = [], i
        while True:
            out.append(pts[k])
            if k == j:
                return out
            k = (k + 1) % len(pts)

    def rev_rot(M, a):
        return [_aff_apply(M, x, y) for x, y in a][::-1]

    A, B = pts[1], pts[19]
    a = _aff_rot(120, A[0], A[1])
    b = _aff_rot(120, B[0], B[1])
    ab = _aff_compose(a, b)
    Cc = _aff_fixed_point(_aff_inv(ab))           # exact third centre
    e0 = arc(1, 10)
    e1 = arc(10, 19)
    e3raw = arc(28, 34)
    v3 = _aff_apply(_aff_inv(b), *pts[10])        # exact corner V3
    # re-anchor the master tail-edge e3 onto the exact corners V3..Cc
    s0, s1 = pts[28], pts[34]
    sl = complex(s1[0] - s0[0], s1[1] - s0[1])
    kk = complex(Cc[0] - v3[0], Cc[1] - v3[1]) / sl
    e3 = [(v3[0] + (complex(x - s0[0], y - s0[1]) * kk).real,
           v3[1] + (complex(x - s0[0], y - s0[1]) * kk).imag) for x, y in e3raw]
    e5 = rev_rot(a, e0)
    e2 = rev_rot(_aff_inv(b), e1)
    e4 = rev_rot(ab, e3)

    outline = []
    for seg in (e0, e1, e2, e3, e4, e5):
        outline += seg[:-1]                       # drop shared joint vertex

    gx = sum(p[0] for p in outline) / len(outline)
    gy = sum(p[1] for p in outline) / len(outline)

    def T(p):
        return ((p[0] - gx) * scale, (p[1] - gy) * scale)

    poly = [T(p) for p in outline]
    # eye: on the head (near the snout, path vertex 7), pulled a little inward
    ex, ey = T(pts[7])
    eye = (ex * 0.82, ey * 0.82)
    return poly, (T(A), T(B)), eye


def subdial(d, cx, cy, r, label, nums=None):
    """The face of an applied analog register drawn over an already-composited
    translucent dark disc: a bright rim, high-contrast 270-degree tick scale
    (gap at the bottom), hub and a bold label -- all white so they read over
    the muted lizards showing through. The needle is a white svg_image node
    drawn on top at runtime."""
    circle(d, cx, cy, r, outline=BLACK, w=3)
    for k in range(11):
        frac = k / 10.0
        ang = (225 + frac * 270) % 360
        major = k in (0, 5, 10)
        x0, y0 = pol(cx, cy, r - (10 if major else 6), ang)
        x1, y1 = pol(cx, cy, r - 2, ang)
        line(d, [x0, y0, x1, y1], fill=BLACK, w=3.0 if major else 1.6)
    if nums:
        for frac, s in nums:
            x, y = pol(cx, cy, r - 19, (225 + frac * 270) % 360)
            text(d, x, y, s, value_font(13), fill=BLACK)
    text(d, cx, cy + r * 0.7, label, value_font(13), fill=BLACK)
    circle(d, cx, cy, 4, fill=BLACK)


def bg_reptile():
    """Escher-style p3 tiling of interlocking lizards under three applied
    analog registers (steps, battery, pointer date)."""
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)

    outline, (A, B), eye = _reptile_tile(scale=0.56)
    TONE = [WHITE, LITE, DARK]

    # Grow the p3 orbit. Two 120-deg rotations about the tile's centres A and B
    # generate the whole group (the derived third centre keeps it consistent),
    # so BFS composes the four generators a, a^-1, b, b^-1 and keys tiles by
    # (rounded world centroid, orientation). Base tile is centred on screen.
    gens = [_aff_rot(120, A[0], A[1]), _aff_rot(-120, A[0], A[1]),
            _aff_rot(120, B[0], B[1]), _aff_rot(-120, B[0], B[1])]
    ident = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    seen = {}
    queue = [ident]

    def key(M):
        k = round(math.degrees(math.atan2(M[2], M[0])) / 120.0) % 3
        return (round(M[4] / 4.0), round(M[5] / 4.0), k)

    seen[key(ident)] = ident
    tiles = []
    while queue and len(tiles) < 500:
        M = queue.pop()
        ix, iy = 120 + M[4], 120 + M[5]           # world centre = M(0,0)
        if -100 <= ix <= 340 and -100 <= iy <= 340:
            tiles.append(M)
        elif not (-220 <= ix <= 460 and -220 <= iy <= 460):
            continue
        for G in gens:
            N = _aff_compose(G, M)
            kk = key(N)
            if kk not in seen:
                seen[kk] = N
                queue.append(N)

    for M in tiles:
        k = round(math.degrees(math.atan2(M[2], M[0])) / 120.0) % 3
        pts = []
        for x, y in outline:
            wx, wy = _aff_apply(M, x, y)
            pts.append(120 + wx)
            pts.append(120 + wy)
        # Flat tone fill + a black ink edge. The geometry now tessellates
        # exactly, so a tile and its neighbour draw this stroke on the SAME
        # shared curve -- it reads as one line (no doubling) and covers any
        # sub-pixel seam, while separating translation-adjacent same-tone
        # lizards.
        d.polygon(P(*pts), fill=TONE[k], outline=BLACK, width=int(1.4 * SS))
        ex, ey = _aff_apply(M, eye[0], eye[1])
        circle(d, 120 + ex, 120 + ey, 2.6, fill=BLACK if k != 2 else WHITE)

    # Three big applied registers over the busy field, packed as large as the
    # round screen allows (120 deg apart, r 50, centres 63 from the middle).
    # The dials are translucent: a baked dark veil mutes the lizards showing
    # through (the watch can't blend a window against a blank framebuffer, so
    # we composite it here -- see bg_seigaiha), then white faces read on top.
    dials = ((65, 89, 'STEP', [(0.0, '0'), (1.0, 'G')]),
             (175, 89, 'BATT', [(0.0, 'E'), (1.0, 'F')]),
             (120, 183, 'DATE', [(0.0, '1'), (0.5, '15'), (1.0, '31')]))
    veil = Image.new('RGBA', img.size, CLEAR)
    vd = ImageDraw.Draw(veil)
    for cx, cy, _, _ in dials:
        circle(vd, cx, cy, 50, fill=TRANSLUCENT)
    img.alpha_composite(veil)
    d = ImageDraw.Draw(img)
    for cx, cy, label, nums in dials:
        subdial(d, cx, cy, 50, label, nums)
    return img


def bg_wicker():
    """A woven basketweave: square straw bundles laid in a checkerboard of
    horizontal and vertical weaves, with four veiled cartouches."""
    img = canvas(bg=WHITE)
    d = ImageDraw.Draw(img)

    T = 30      # tile pitch
    pad = 2     # gap between straw bundles (reads as the over/under weave)
    n = 240 // T
    for gy in range(-1, n + 1):
        for gx in range(-1, n + 1):
            x0, y0 = gx * T, gy * T
            horiz = (gx + gy) % 2 == 0
            d.rounded_rectangle(P(x0 + pad, y0 + pad, x0 + T - pad,
                                  y0 + T - pad), radius=4 * SS, fill=LITE)
            # grooves along the weave direction give each bundle its grain
            for k in range(1, 4):
                if horiz:
                    yy = y0 + k * T / 4.0
                    line(d, [x0 + pad + 2, yy, x0 + T - pad - 2, yy],
                         fill=DARK, w=1.2)
                else:
                    xx = x0 + k * T / 4.0
                    line(d, [xx, y0 + pad + 2, xx, y0 + T - pad - 2],
                         fill=DARK, w=1.2)

    # Thin bezel to frame the weave.
    circle(d, 120, 120, 117, outline=DARK, w=2)

    # Four cartouches. Subdue (don't punch out) the weave under each with a
    # baked translucent veil so the texture still reads faintly behind the
    # black text (the watch can't blend a window against blank framebuffer;
    # see bg_seigaiha).
    windows = ((86, 40, 172, 70),      # steps (top)
               (28, 108, 104, 138),    # calories (left)
               (136, 108, 212, 138),   # battery (right)
               (68, 182, 172, 208))    # date (bottom)
    veil = Image.new('RGBA', img.size, (0, 0, 0, 0))
    vd = ImageDraw.Draw(veil)
    for x0, y0, x1, y1 in windows:
        vd.rounded_rectangle(P(x0, y0, x1, y1), radius=7 * SS,
                             fill=TRANSLUCENT)
    img.alpha_composite(veil)
    for x0, y0, x1, y1 in windows:
        d.rounded_rectangle(P(x0, y0, x1, y1), radius=7 * SS,
                            outline=DARK, width=int(1.4 * SS))

    # Baked label glyphs (the value text is placed to the right of each).
    shoe(d, 99, 55, 15, fill=BLACK)
    flame(d, 42, 122, 15, fill=BLACK)
    battery(d, 150, 121, 16, fill=BLACK)
    return img


DOWS3 = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT']

# scale geometry, shared between the background and app.js angle maps
REG_CENTER = (120, 120)
REG_MONTHS = 'JFMAMJJASOND'
REG_MON_PIVOT = (43, 34)     # month hand pivot, up at the top-left
REG_MON_R = 65               # month label radius (about the pivot)
REG_DOW_CENTER = (184, 122)  # weekday sub-dial centre
REG_DOW_R = 40               # weekday sub-dial radius
REG_DATE_CENTER = (120, 182)  # date sub-dial centre (just below half-way)
REG_DATE_R = 47              # date label radius (about that centre)
# --- Breguet bosom-moon aperture ---------------------------------------
# The aperture is a half-disc: a straight edge with the two dial lobes
# sitting on it as semicircular bumps, and a big arc of sky over them.
# The starry disc turns about REG_MOON_PIVOT — the MIDPOINT of the two
# lobe centres — so a moon parked on a lobe centre is exactly, entirely
# hidden by it (age 0), and the very next frame lifts a sliver of it out
# from behind the lobe.  The lobe rim doubles as the terminator: it eats
# the moon's edge on the way up and again on the way down, which is how
# these apertures fake the phases.
REG_MOON_PIVOT = (170, 59)   # disc rotation centre = lobe midpoint
REG_MOON_TILT = 40           # watch angle (cw) the aperture opens towards
REG_MOON_HALF = 18           # half the lobe separation = moon orbit radius
REG_MOON_RM = 12             # moon radius
REG_MOON_RL = 12.5           # lobe radius; a hair over RM so age 0 is clean
REG_MOON_RD = 34             # aperture radius


def reg_moon_pt(u, v):
    """Screen point `u` along the aperture's straight edge and `v` into the
    sky, measured from the pivot (the complication's own frame)."""
    th = math.radians(REG_MOON_TILT)
    px, py = REG_MOON_PIVOT
    return (px + u * math.cos(th) + v * math.sin(th),
            py + u * math.sin(th) - v * math.cos(th))


# The moon is a raster sprite swapped by phase (image node on top of the
# dial) rather than a live svg — svg_image under a punched window and
# multi-subpath fills don't render on the watch.  One frame per disc
# rotation over a synodic month (the two-moon disc turns 180 deg).
REG_MOON_FRAMES = 30
REG_MOON_CROP = (135, 24, 205, 94)      # sprite bbox on the 240 canvas
# stars in the disc's own frame: (radius, angle from the lobe axis, size).
# They ride round with the disc, so each one drifts through the sky over
# the month; anything past the aperture radius is simply clipped away.
REG_MOON_STARS = [(7, 118, 1.1), (9, 24, 1.3), (11, 196, 1.0), (12, 78, 1.2),
                  (13, 302, 1.1), (15, 152, 1.3), (16, 8, 1.0), (17, 244, 1.2),
                  (19, 96, 1.1), (20, 330, 1.3), (21, 176, 1.0), (22, 46, 1.2),
                  (23, 268, 1.1), (24, 130, 1.3), (25, 356, 1.0), (26, 208, 1.2),
                  (27, 62, 1.1), (28, 288, 1.2), (29, 144, 1.0), (30, 18, 1.3),
                  (30, 226, 1.1), (31, 104, 1.2), (32, 316, 1.0), (32, 166, 1.1)]


def render_regence_moon_frame(i, n=REG_MOON_FRAMES):
    """One frame of the bosom-moon: the starry disc (two moons + stars)
    turned to rotation i about the lobe midpoint and clipped to the
    aperture, with the two dial lobes and their bezels on top.  Frame 0 is
    the new moon, dead behind the lower lobe; the disc walks it up over the
    crown and down behind the other lobe in half a turn.  Cropped to the
    aperture bbox; drawn over the dial."""
    rd = REG_MOON_RD
    phi = i * (180.0 / n)                   # disc rotation for this frame

    def spin(r, a):
        """Point at disc-radius r, disc-angle a, once the disc has turned."""
        t = math.radians(a + phi)
        return reg_moon_pt(r * math.cos(t), r * math.sin(t))

    img = Image.new('RGBA', (W * SS, W * SS), CLEAR)
    pcx, pcy = REG_MOON_PIVOT
    dome = P(pcx - rd, pcy - rd, pcx + rd, pcy + rd)
    a0 = REG_MOON_TILT + 180                # PIL start angle of the sky half

    # night sky + stars + the two moons, all clipped to the aperture
    sky = Image.new('RGBA', img.size, CLEAR)
    sd = ImageDraw.Draw(sky)
    sd.pieslice(dome, a0, a0 + 180, fill=BLACK)
    for R, ang, sr in REG_MOON_STARS:
        x, y = spin(R, ang)
        circle(sd, x, y, sr, fill=WHITE)
    for ang in (0, 180):        # two moons, half a turn apart on the disc
        x, y = spin(REG_MOON_HALF, ang)
        circle(sd, x, y, REG_MOON_RM, fill=LITE)   # one shade below white
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).pieslice(dome, a0, a0 + 180, fill=255)
    sky.putalpha(ImageChops.multiply(sky.split()[3], mask))
    img.alpha_composite(sky)

    # the two dial lobes sit on the straight edge, over the sky
    d = ImageDraw.Draw(img)
    rl = REG_MOON_RL
    lobes = [reg_moon_pt(-REG_MOON_HALF, 0), reg_moon_pt(REG_MOON_HALF, 0)]
    for lx, ly in lobes:
        circle(d, lx, ly, rl, fill=WHITE)
    d.arc(dome, a0, a0 + 180, fill=DARK, width=int(1.4 * SS))
    for lx, ly in lobes:
        d.arc(P(lx - rl, ly - rl, lx + rl, ly + rl), a0, a0 + 180,
              fill=DARK, width=int(1.1 * SS))

    x0, y0, x1, y1 = REG_MOON_CROP
    return img.crop((x0 * SS, y0 * SS, x1 * SS, y1 * SS))


def reg_month_angle(m):
    # ~120 deg fan: Jan at the 9:15 rim, Dec at 12 o'clock, pivoting at
    # the top-left so the hand reaches out over the upper-left of the dial
    return 199 - m * (121.0 / 11.0)


def reg_date_angle(d):
    # a near-full retrograde ring about the lower sub-dial: 1 just right of
    # top, sweeping clockwise all the way round to 31 just left of top
    return 5 + (d - 1) * (350.0 / 30.0)


def reg_dow_angle(w):
    # the seven days evenly around the whole sub-dial, Sun at the top
    return w * (360.0 / 7.0)


def reg_upright_tangent(a):
    """Rotation (deg cw) that sets text tangent to a circle at watch-angle
    `a`, flipped 180 where needed so it never goes past upright."""
    t = ((a + 180) % 360) - 180
    if t > 90:
        t -= 180
    elif t < -90:
        t += 180
    return t


def bg_regence():
    """A white calendar dial in the spirit of a Breguet Classique: a plain
    silver field, a retrograde month sub-dial pivoting up at ~10:40, a big
    central retrograde date, a weekday sub-dial on the right and a
    Breguet bosom-moon aperture upper-right.  The three hands are svg_image
    needles and the moon is a sprite, all drawn at runtime."""
    cx, cy = REG_CENTER
    px, py = REG_MON_PIVOT
    dcx, dcy = REG_DATE_CENTER
    wcx, wcy = REG_DOW_CENTER
    img = canvas(bg=BLACK)
    d = ImageDraw.Draw(img)

    # plain silver-white dial with a fine bezel ring
    circle(d, cx, cy, 118, fill=WHITE)
    circle(d, cx, cy, 116, outline=LITE, w=1.5)

    # ---- month retrograde fan: every other month a letter, the rest dots
    for m in range(12):
        a = reg_month_angle(m)
        x, y = pol(px, py, REG_MON_R, a)
        if m % 2 == 0:
            stamp(img, x, y, REG_MONTHS[m], serif_font_bold(14), fill=BLACK,
                  angle=reg_upright_tangent(a))
        else:
            circle(d, x, y, 1.7, fill=BLACK)
    circle(d, px, py, 4.5, fill=BLACK)      # month hand hub

    # ---- date retrograde ring: odd numbers tangent (kept upright), dots
    for dd_ in range(1, 32):
        a = reg_date_angle(dd_)
        x, y = pol(dcx, dcy, REG_DATE_R, a)
        if dd_ % 2 == 1:
            stamp(img, x, y, str(dd_), serif_font_bold(14), fill=BLACK,
                  angle=reg_upright_tangent(a))
        else:
            circle(d, x, y, 1.5, fill=DARK)
    circle(d, dcx, dcy, 5, fill=BLACK)      # date hand hub

    # ---- weekday sub-dial: single big initials around the whole circle ----
    for w in range(7):
        a = reg_dow_angle(w)
        lx, ly = pol(wcx, wcy, REG_DOW_R - 12, a)
        stamp(img, lx, ly, DOWS3[w][0], serif_font_bold(18), fill=BLACK,
              angle=reg_upright_tangent(a))
    circle(d, wcx, wcy, 6, fill=BLACK)      # weekday hand hub

    # (the moon complication is a phase sprite drawn on top at runtime)

    # clip everything to the round dial on black
    final = Image.new('RGBA', img.size, BLACK)
    fmask = Image.new('L', img.size, 0)
    ImageDraw.Draw(fmask).ellipse(P(cx - 119, cy - 119, cx + 119, cy + 119),
                                  fill=255)
    final.paste(img, (0, 0), fmask)
    return final


BACKGROUNDS = {'sector': bg_sector, 'meteo': bg_meteo, 'rings': bg_rings,
               'pulse': bg_pulse, 'daily': bg_daily, 'fluted': bg_fluted,
               'reserve': bg_reserve, 'tty': bg_tty, 'radar': bg_radar,
               'retro': bg_retro, 'gnomon': bg_gnomon, 'iris': bg_iris,
               'piet': bg_piet, 'glass': bg_glass, 'arcade': bg_arcade,
               'gazette': bg_gazette, 'schema': bg_schema,
               'transit': bg_transit, 'calc': bg_calc, 'todo': bg_todo,
               'grande': bg_grande, 'grande2': bg_grande2,
               'horizon': bg_horizon, 'meridian': bg_meridian,
               'almanac': bg_almanac,
               'split': bg_split, 'stack': bg_stack,
               'type': bg_type, 'rayon': bg_rayon,
               'deco': bg_deco, 'aria': bg_aria,
               'ivory': bg_ivory, 'seigaiha': bg_seigaiha,
               'argyle': bg_argyle, 'wicker': bg_wicker,
               'reptile': bg_reptile, 'regence': bg_regence}



# ------------------------------------------------------------ interface

def render_icon(name):
    img = Image.new('RGBA', (48 * SS, 48 * SS), CLEAR)
    weather_icons()[name](ImageDraw.Draw(img))
    return img


def render_moon_icon(i):
    """36x36 moonphase disc, index 0 (new) .. 7 (waning crescent).
    Shadow = same-size dark disc slid across the lit disc, then clipped to
    the moon's circle so the shadow never spills onto the (transparent)
    background."""
    c, r = 18, 15
    disc = Image.new('RGBA', (36 * SS, 36 * SS), CLEAR)
    dd = ImageDraw.Draw(disc)
    circle(dd, c, c, r, fill=WHITE)
    if i == 0:
        circle(dd, c, c, r, fill=BLACK)
    elif i < 4:                          # waxing: shadow slides off left
        circle(dd, c - i * r / 2, c, r, fill=BLACK)
    elif i > 4:                          # waning: shadow slides in right
        circle(dd, c + (8 - i) * r / 2, c, r, fill=BLACK)
    mask = Image.new('L', disc.size, 0)
    ImageDraw.Draw(mask).ellipse(P(c - r, c - r, c + r, c + r), fill=255)
    img = Image.new('RGBA', (36 * SS, 36 * SS), CLEAR)
    img.paste(disc, (0, 0), mask)
    circle(ImageDraw.Draw(img), c, c, r, outline=LITE, w=1.4)
    return img


def render_glint():
    """12x12 white catch-light for the iris face."""
    img = Image.new('RGBA', (12 * SS, 12 * SS), CLEAR)
    d = ImageDraw.Draw(img)
    circle(d, 6, 6, 5.4, fill=WHITE)
    return img


def render_checkbox(checked):
    """20x20 hand-drawn checkbox for the todo face."""
    img = Image.new('RGBA', (20 * SS, 20 * SS), CLEAR)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(P(2, 4, 16, 18), radius=2 * SS, outline=BLACK,
                        width=int(2 * SS))
    if checked:
        line(d, [5, 11, 9, 15], fill=BLACK, w=2.5)
        line(d, [9, 15, 18, 2], fill=BLACK, w=2.5)
    return img


def render_todo_goal_glyph(ch):
    """A glyph cell for Todo's dynamic target, in its handwritten font."""
    img = Image.new('RGBA', (16 * SS, 24 * SS), CLEAR)
    d = ImageDraw.Draw(img)
    d.text(P(8, 12), ch, font=marker_font(16), fill=BLACK, anchor='mm')
    return img


def render(face, outdir):
    """Render all icon-section images for `face`; returns {name: path}."""
    out = {}

    def save(name, img, size=None):
        path = os.path.join(outdir, name + '.png')
        finish(img, size).save(path)
        out[name] = path

    save('background', BACKGROUNDS[face]())
    if face == 'meteo':
        for name in weather_icons():
            save(name, render_icon(name), 48)
    if face == 'reserve' or face == 'seigaiha':
        for i in range(8):
            save('phase' + str(i), render_moon_icon(i), 36)
    if face == 'iris':
        save('glint', render_glint(), 12)
    if face == 'todo':
        save('box', render_checkbox(False), 20)
        save('boxck', render_checkbox(True), 20)
        for ch in '0123456789k':
            save('goal' + ch, render_todo_goal_glyph(ch), (16, 24))
        save('goalDot', render_todo_goal_glyph('.'), (16, 24))
    if face in ('grande', 'grande2'):
        for i in range(8):
            save('phase' + str(i), render_moon_icon(i), 36)
    if face == 'horizon':
        save('sunorb', render_orb('sunorb'), 18)
        save('moonorb', render_orb('moonorb'), 18)
    if face == 'meridian':
        for name in ('dsun', 'dmoon', 'dnone'):
            save(name, render_daynight(name), 14)
    if face == 'almanac':
        save('mark', render_mark())
    if face == 'regence':
        x0, y0, x1, y1 = REG_MOON_CROP
        for i in range(REG_MOON_FRAMES):
            save('moon%02d' % i, render_regence_moon_frame(i), (x1 - x0, y1 - y0))
    return out


def render_preview(face, outdir):
    """The companion-app thumbnail / on-watch !preview.rle.

    Drawn by the same engine that renders the face on the watch: the
    face's real layout.json places the real values its app.js computes
    for the `day` scenario (layout_engine.py), over the assets
    render() just wrote into `outdir`.  So a preview needs no per-face
    code at all, and can't drift from the layout.

    Assets come from the PNGs rather than the compiled RLE so the
    thumbnail keeps its antialiasing; the screen is left unmasked
    because the companion app clips previews to a circle itself."""
    img, _ = layout_engine.render_face(
        face, 'day', icons=layout_engine.load_icons_png(outdir), mask=False)
    path = os.path.join(outdir, face + 'Face.png')
    # flatten: transparent gauge windows must read as the black screen
    img.convert('RGB').save(path)
    return path
