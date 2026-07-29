#!/usr/bin/env python3
"""Build every watch face in this directory into a .wapp.

For each face directory (one per face, containing app.json, app.js,
layout.json and an entry in gen_assets.py):

  1. render the icon/background assets with PIL (gen_assets.py)
  2. compress them to the watch RLE format (SDK image_compress.py)
  3. compile app.js to a JerryScript 2.1.0 snapshot
  4. assemble the five-section files/ tree and pack it (SDK pack.py)

The finished .wapp lands next to the face directories, named after the
identifier from the face's app.json.  Run `make deps` here first if
vendor/ is empty.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from layout_engine import (FACES, JERRY_SNAPSHOT, NOT_BUNDLED,   # noqa: E402
                           ROOT, SDK_TOOLS)

# built faces ship inside the iOS companion app — all but NOT_BUNDLED
BUNDLE_DIR = os.path.join(ROOT, 'Resources', 'bundled_faces')

# firmware limits (see repo CLAUDE.md)
MAX_SECTION_FILE = 65535
MAX_LAYOUT_NODES = 21   # proven good: official Mechanical_Black runs 21


def run(cmd, **kw):
    subprocess.run(cmd, check=True, **kw)


def compress(png, out, fmt='rle'):
    run([sys.executable, os.path.join(SDK_TOOLS, 'image_compress.py'),
         '-f', fmt, '-i', png, '-o', out])


def build_face(face):
    src = os.path.join(HERE, face)
    out = os.path.join(src, 'build')
    files = os.path.join(out, 'files')
    shutil.rmtree(out, ignore_errors=True)
    for section in ['code', 'icons', 'layout', 'display_name', 'config']:
        os.makedirs(os.path.join(files, section))

    with open(os.path.join(src, 'app.json')) as f:
        meta = json.load(f)
    identifier = meta['identifier']
    assert meta['version'].split('.')[0] == '1', \
        f'{face}: watchfaces must have version type byte 1'
    shutil.copy(os.path.join(src, 'app.json'), os.path.join(out, 'app.json'))

    # 1+2. assets: gen_assets renders PNGs into build/png, then compress
    import gen_assets
    png_dir = os.path.join(out, 'png')
    os.makedirs(png_dir)
    images = gen_assets.render(face, png_dir)   # {icon_name: png_path}
    for name, png in images.items():
        compress(png, os.path.join(files, 'icons', name))
    # preview for companion apps
    preview = gen_assets.render_preview(face, png_dir)
    compress(preview, os.path.join(files, 'icons', '!preview.rle'))

    # 3. layout (validated) — packed under the face's layout name
    with open(os.path.join(src, 'layout.json')) as f:
        layout = json.load(f)
    assert len(layout) <= MAX_LAYOUT_NODES, \
        f'{face}: {len(layout)} layout nodes exceeds proven limit {MAX_LAYOUT_NODES}'
    with open(os.path.join(files, 'layout', meta['layout_name']), 'w') as f:
        json.dump(layout, f, separators=(',', ':'))

    # 4. code snapshot — file name must equal the identifier
    run([JERRY_SNAPSHOT, 'generate', '-f', '',
         os.path.join(src, 'app.js'),
         '-o', os.path.join(files, 'code', identifier)])

    with open(os.path.join(files, 'display_name', 'display_name'), 'w') as f:
        f.write(meta['display_name'])
    with open(os.path.join(files, 'display_name', 'theme_class'), 'w') as f:
        f.write('complications')
    # one-line blurb for companion-app face lists; the watch only looks
    # section files up by name, so an extra entry here is inert bytes
    if meta.get('description'):
        with open(os.path.join(files, 'display_name', 'description'), 'w') as f:
            f.write(meta['description'])

    for dirpath, _, filenames in os.walk(files):
        for fn in filenames:
            size = os.path.getsize(os.path.join(dirpath, fn))
            assert size <= MAX_SECTION_FILE, f'{face}: {fn} is {size} bytes'

    wapp = os.path.join(HERE, identifier + '.wapp')
    run([sys.executable, os.path.join(SDK_TOOLS, 'pack.py'),
         '-i', out, '-o', wapp])
    assert open(wapp, 'rb').read()[12] == 1, f'{face}: type byte is not watchface'
    print(f'{face}: {wapp} ({os.path.getsize(wapp)} bytes)')

    # bundle into the companion app: <identifier>.wapp + <identifier>.png
    if face in NOT_BUNDLED:
        return
    os.makedirs(BUNDLE_DIR, exist_ok=True)
    shutil.copy(wapp, os.path.join(BUNDLE_DIR, identifier + '.wapp'))
    shutil.copy(preview, os.path.join(BUNDLE_DIR, identifier + '.png'))


def main():
    faces = sys.argv[1:] or FACES
    for face in faces:
        build_face(face)


if __name__ == '__main__':
    main()
