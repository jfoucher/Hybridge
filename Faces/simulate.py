#!/usr/bin/env python3
"""A desk-side Fossil Hybrid HR screen simulator.

Renders what the watch will actually draw for a face — not a mockup:

  * the face's real app.js runs under the desktop jerry CLI and its
    handler produces the real layout_info for a chosen scenario;
  * the face's real layout.json places everything, and the real
    compiled RLE icons are taken from its build/ tree (run build.py
    first);
  * layout_parser_json semantics live in layout_engine.py, shared with
    the preview generator in gen_assets.py.

Usage:
  python3 simulate.py sector                  # one face -> build/sim-day.png
  python3 simulate.py --scenario ace          # every face
  python3 simulate.py --sheet sheet.png       # contact sheet of all faces
  python3 simulate.py --audit                 # text vs hub/edge/text
"""
import argparse
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

from layout_engine import (FACES, FONT, FONT_INDEX, HUB_R, NOT_BUNDLED,
                           SCENARIOS, layout_info_for, load_layout,
                           render_face, text_metrics)

HERE = os.path.dirname(os.path.abspath(__file__))


def render(face, scenario='day'):
    return render_face(face, scenario)


# ----------------------------------------------------------------- audit
#
# The watch font's metrics are not exactly Helvetica's, and the engine's
# vertical centering inside a text container is only approximately the
# ascent/descent formula.  So the audit is pessimistic: glyph boxes are
# widened 25% horizontally and 6px vertically before collision checks.

W_SLOP = 1.25
V_SLOP = 6                    # vertical uncertainty vs hub/screen edge
V_SLOP_TT = 1                 # text-vs-text: vertical metrics are close
# hub radius: the 12.5 measured on the watch plus a small pad. It used
# to be 10+4; now that the hub itself is measured the pad only covers
# how well the layout lands, and V_SLOP already pads the text box.
HUB = (120, 120, HUB_R + 2)
SCREEN_R = 118


def text_boxes(face, info, common):
    """Pessimistic glyph bounding boxes for every text node."""
    layout = load_layout(face)
    nodes = {n['id']: n for n in layout}
    boxes = []
    for node in layout:
        if node['type'] != 'text' or not node.get('visible', True):
            continue
        s, box, _, _ = text_metrics(node, nodes.get(node.get('parent_id')),
                                    info, common, slop=W_SLOP)
        boxes.append((s, box))
    return boxes


def grow(b, v):
    return (b[0], b[1] - v, b[2], b[3] + v)


def audit(faces, scenarios=('day', 'ace')):
    bad = 0
    for face in faces:
        findings = []
        for scenario in scenarios:
            info, common = layout_info_for(face, scenario)
            boxes = text_boxes(face, info, common)
            for i, (s, raw) in enumerate(boxes):
                b = grow(raw, V_SLOP)
                # hub: closest point of box vs hub circle
                cx = max(b[0], min(HUB[0], b[2]))
                cy = max(b[1], min(HUB[1], b[3]))
                if math.hypot(cx - HUB[0], cy - HUB[1]) < HUB[2]:
                    findings.append(
                        f'[{scenario}] "{s}" may hit the hands hub {raw}')
                # round screen edge: any corner outside
                for x, y in ((b[0], b[1]), (b[2], b[1]),
                             (b[0], b[3]), (b[2], b[3])):
                    if math.hypot(x - 120, y - 120) > SCREEN_R:
                        findings.append(
                            f'[{scenario}] "{s}" leaves the screen {raw}')
                        break
                t = grow(raw, V_SLOP_TT)
                for s2, raw2 in boxes[i + 1:]:
                    b2 = grow(raw2, V_SLOP_TT)
                    if (t[0] < b2[2] and b2[0] < t[2]
                            and t[1] < b2[3] and b2[1] < t[3]):
                        findings.append(
                            f'[{scenario}] "{s}" overlaps "{s2}"')
        if findings:
            bad += 1
            print(f'{face}:')
            for f in sorted(set(findings)):
                print(f'  {f}')
        else:
            print(f'{face}: clean')
    print(f'\n{bad} face(s) with findings')
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('faces', nargs='*', default=FACES)
    ap.add_argument('--scenario', default='day', choices=SCENARIOS)
    ap.add_argument('--sheet', help='write an all-faces contact sheet PNG')
    ap.add_argument('--audit', action='store_true',
                    help='check text vs hub / screen edge / other text')
    args = ap.parse_args()

    if args.audit:
        sys.exit(1 if audit(args.faces or FACES) else 0)

    shots = []
    for face in (args.faces or FACES):
        img, info = render(face, args.scenario)
        out = os.path.join(HERE, face, 'build', f'sim-{args.scenario}.png')
        os.makedirs(os.path.dirname(out), exist_ok=True)
        img.save(out)
        if face in NOT_BUNDLED:
            continue
        shots.append((face, img))
        print(f'{face}: {out}')

    if args.sheet:
        cols, cell, label_h = 5, 240, 24
        rows = math.ceil(len(shots) / cols)
        sheet = Image.new('RGB', (cols * (cell + 8) + 8,
                                  rows * (cell + label_h + 8) + 8),
                          (24, 24, 24))
        sd = ImageDraw.Draw(sheet)
        font = ImageFont.truetype(FONT, 15, index=FONT_INDEX)
        for i, (face, img) in enumerate(shots):
            x = 8 + (i % cols) * (cell + 8)
            y = 8 + (i // cols) * (cell + label_h + 8)
            sheet.paste(img.convert('RGB'), (x, y))
            sd.text((x + cell / 2, y + cell + 5), face, font=font,
                    fill=(200, 200, 200), anchor='ma')
        sheet.save(args.sheet)
        print(f'sheet: {args.sheet}')


if __name__ == '__main__':
    main()
