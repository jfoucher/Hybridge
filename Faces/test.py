#!/usr/bin/env python3
"""Smoke-test every face's app.js under the desktop jerry CLI.

Wraps app.js in a function (snapshots are function bodies), runs it
with the engine mocks and the event-sequence driver, then asserts:

  * every '#placeholder' the layout references is produced on each draw
  * boot answers go_visible/home
  * becoming visible starts the timer, draws du4, and moves the hands
  * the 15th minute tick is a full du4 refresh
  * buttons are forwarded, hidden stops the timer, stray ticks don't draw
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from layout_engine import FACES, JERRY         # noqa: E402


def layout_placeholders(layout):
    """All placeholder names used anywhere in the layout tree, except
    '#common.*' bindings which the engine fills itself.  A layout says
    '#name' but layout_info must supply the key WITHOUT the hash — the
    engine strips it (see moonphase/simple app.js, proven on-watch)."""
    found = set()

    def walk(v):
        if isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, str) and v.startswith('#') \
                and not v.startswith('#common.'):
            found.add(v[1:])
    walk(layout)
    return found


def run_face(face):
    src = os.path.join(HERE, face)
    app = open(os.path.join(src, 'app.js')).read()
    wrapped = 'var app = (function () {\n' + app + '\n})();\n'
    # A non-default target proves Todo renders the configured goal rather than
    # accidentally baking the old "10k" label back into its background.
    if face == 'todo':
        wrapped += 'common.daily_goal.steps = 8500;\n'
    tmp = os.path.join(src, 'build', 'wrapped.js')
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    with open(tmp, 'w') as f:
        f.write(wrapped)

    proc = subprocess.run(
        [JERRY, os.path.join(HERE, 'harness', 'mocks.js'), tmp,
         os.path.join(HERE, 'harness', 'driver.js')],
        capture_output=True, text=True)
    if proc.returncode != 0:
        raise AssertionError(f'{face}: jerry failed\n{proc.stdout}{proc.stderr}')

    responses, log = {}, []
    for line in proc.stdout.splitlines():
        if line.startswith('RESP '):
            _, name, payload = line.split(' ', 2)
            responses[name] = json.loads(payload)
        elif line.startswith('LOG '):
            log = json.loads(line[4:])
    return responses, log


def check_face(face):
    with open(os.path.join(HERE, face, 'layout.json')) as f:
        layout = json.load(f)
    meta = json.load(open(os.path.join(HERE, face, 'app.json')))
    needed = layout_placeholders(layout)
    responses, log = run_face(face)

    ids = {n['id'] for n in layout}
    for n in layout:
        assert 'parent_id' not in n or n['parent_id'] in ids, \
            f'{face}: node {n["id"]} has unknown parent'

    r = responses['boot']
    assert r.get('action') == {'type': 'go_visible', 'class': 'home'}, \
        f'{face}: bad boot action: {r}'

    def draw_info(name, expect_type):
        r = responses[name]
        assert r.get('draw', {}).get('update_type') == expect_type, \
            f'{face}: {name} update_type != {expect_type}: {r.get("draw")}'
        info = r['draw']['']['layout_info']
        assert info['json_file'] == meta['layout_name'], \
            f'{face}: {name} json_file mismatch'
        assert not any(k.startswith('#') for k in info), \
            f'{face}: {name} layout_info keys must not carry the hash'
        have = set(info) - {'json_file'}
        assert needed <= have, \
            f'{face}: {name} missing placeholders {needed - have}'
        return info

    draw_info('visible', 'du4')
    assert responses['visible'].get('move') == \
        {'h': 123, 'm': 231, 'is_relative': False}, f'{face}: no hands move'
    draw_info('tick', 'gu4')
    draw_info('common', 'gu4')
    info = draw_info('data', 'gu4')
    draw_info('tick15', 'du4')          # 15th minute since visible

    # face-specific: live data must actually land in the placeholders
    if face == 'meteo':
        assert info['temp'] == '21C' and info['wicon'] == 'wxPartDay' \
            and info['rain'] == '30%' and info['uv'] == '5', \
            f'{face}: weather not applied: {info}'
        assert any(x.startswith('req_data:') for x in log), \
            f'{face}: never asked for weather'
    if face == 'daily':
        assert info['temp'] == '21C' and info['dow'] == 'SATURDAY' \
            and info['date'] == '18' and info['month'] == 'JULY', \
            f'{face}: bad computed fields: {info}'
    if face in ('sector', 'pulse'):
        assert info['bpm'] == '72', f'{face}: hr_bpm not applied: {info}'
    if face == 'pulse':
        assert info['dwd'] == 'SAT 18', f'{face}: bad weekday: {info}'
    if face == 'rings':
        assert info['barc'] == 273 and info['steps'] == '12.3k', \
            f'{face}: bad ring math: {info}'
    if face in ('fluted', 'reserve'):
        assert info['date'] == '18', f'{face}: bad date: {info}'
    if face == 'reserve':
        # 2026-07-18 is ~4 days past new moon -> waxing crescent;
        # battery 78% -> fan arc 120 + 78*1.2 = 214
        assert info['moon'] == 'phase1', f'{face}: bad moonphase: {info}'
        assert info['barc'] == 214, f'{face}: bad reserve arc: {info}'
    if face == 'tty':
        assert info['l1'] == 'SAT 18 JUL' and info['l2'] == 'STEP 12345' \
            and info['l4'] == 'BPM 72' and info['l5'] == 'BATT 78%', \
            f'{face}: bad lines: {info}'
    if face == 'radar':
        # mock epoch 1784732400 with tz +120 min lands on minute 0
        assert info['sweep'] == 0 and info['hud1'] == '12.3k STEPS' \
            and info['hud2'] == '72 BPM', f'{face}: bad hud: {info}'
    if face == 'retro':
        # 12345/10000 steps caps the fan at +60; battery 78% -> +33.6
        assert info['srot'] == 60 and info['brot'] == 34 \
            and info['date'] == '18', f'{face}: bad needles: {info}'
    if face == 'gnomon':
        # mock local time is 17:00 -> 1020/1440 of a day + 180 offset
        assert info['grot'] == 75 and info['date'] == 'XVIII', \
            f'{face}: bad sundial: {info}'
    if face == 'iris':
        # minute 0: glint straight up at radius 34, 12px icon offset -6
        assert info['gx'] == 114 and info['gy'] == 80, \
            f'{face}: bad glint: {info}'
    if face == 'piet':
        # battery 78% of the 68px window, bottom-anchored at y=144
        assert info['bh'] == 53 and info['btop'] == 91 \
            and info['steps'] == '12.3k', f'{face}: bad gauge: {info}'
    if face == 'glass':
        # 17:00 -> 70.8% of the day gone: top sand 17px (fp round-down),
        # bottom 48px
        assert info['t1t'] == 89 and info['t1h'] == 17 \
            and info['t2t'] == 154 and info['t2h'] == 48 \
            and info['dwd'] == 'SAT 18', f'{face}: bad sand: {info}'
    if face == 'arcade':
        assert info['score'] == '012345' and info['hi'] == '010000' \
            and info['batt'] == '78%', f'{face}: bad scoreboard: {info}'
    if face == 'gazette':
        assert info['dateline'] == 'SAT, JUL 18' \
            and info['head1'] == '12,345 STEPS' \
            and info['head2'] == '486 KCAL' \
            and info['wx'] == '21C' and info['mkt'] == '78%', \
            f'{face}: bad front page: {info}'
        assert any(x.startswith('req_data:') for x in log), \
            f'{face}: never asked for weather'
    if face == 'schema':
        assert info['date'] == '18' and info['steps'] == '12.3k' \
            and info['batt'] == '78%', f'{face}: bad title block: {info}'
    if face == 'transit':
        assert info['steps'] == '12.3k' and info['kcal'] == '486' \
            and info['bpm'] == '72' and info['batt'] == '78%', \
            f'{face}: bad terminals: {info}'
    if face == 'calc':
        assert info['lcd'] == '12345' and info['mem'] == 'M 486' \
            and info['date'] == '18 JUL', f'{face}: bad display: {info}'
    if face == 'grande':
        # Sat=6 -> 309deg; 18th -> 197; July -> 180; 17:00 -> 75;
        # 72bpm -> 306; 42min -> 60; 12345 steps caps at 150;
        # 486 kcal -> 30+36; 78% -> 210+47; moon: waxing crescent
        assert info['moon'] == 'phase1' and info['dowrot'] == 309 \
            and info['daterot'] == 197 and info['monrot'] == 180 \
            and info['rot24'] == 75 and info['hrrot'] == 306 \
            and info['actrot'] == 60 and info['steprot'] == 150 \
            and info['karc'] == 66 and info['barc'] == 257, \
            f'{face}: bad complication: {info}'
    if face == 'grande2':
        # orbiting dots share the pointer math; month fan July -> +5,
        # 486 kcal on the 60-degree rim arc -> 30+36
        assert info['moon'] == 'phase1' and info['daterot'] == 197 \
            and info['dowrot'] == 309 and info['monrot'] == 5 \
            and info['karc'] == 66 and info['steprot'] == 150 \
            and info['actrot'] == 60 and info['hrrot'] == 306 \
            and info['barc'] == 257, \
            f'{face}: bad complication: {info}'
    if face == 'horizon':
        # Paris (the config default) on 2026-07-18, local 17:00: the
        # sun times match the moonphase app's SunCalc port to the
        # minute, 4h48 of daylight left, orb past noon so the spent
        # arc has wrapped past 360 onto the second node
        assert info['rise'] == '06:07' and info['set'] == '21:48' \
            and info['big'] == '4h48' and info['orb'] == 'sunorb' \
            and info['cap'] == 'OF DAYLIGHT LEFT' \
            and info['s1'] == 270 and info['e1'] == 360 \
            and info['s2'] == 0 and info['e2'] == 35, \
            f'{face}: bad sun clock: {info}'
    if face == 'meridian':
        # local 17:00 at UTC+2; Tokyo has already rolled over midnight
        assert info['ltime'] == '17:00' \
            and info['date'] == 'SAT 18 JUL  UTC+2' \
            and info['t1'] == '15:00' and info['i1'] == 'dsun' \
            and info['t2'] == '11:00' and info['l2'] == 'NYC' \
            and info['t3'] == '00:00 +1' and info['i3'] == 'dmoon', \
            f'{face}: bad world timer: {info}'
    if face == 'almanac':
        # Sat 18 Jul 2026 is ISO week 29, day 199; the strip runs
        # Mon 13 .. Sun 19 with the box on the sixth column
        assert info['week'] == 'WEEK 29' and info['doy'] == 'DAY 199 OF 365' \
            and info['d0'] == '13' and info['d5'] == '18' \
            and info['d6'] == '19' and info['mx'] == 165 \
            and info['yarc'] == 196 and info['month'] == 'JULY 2026', \
            f'{face}: bad calendar: {info}'
    if face == 'todo':
        # configured target 8500 is rendered; 12345>=8500 checks the row
        assert info['c1'] == 'boxck' and info['c2'] == 'boxck' \
            and info['c3'] == 'boxck' and info['c4'] == 'box' \
            and info['gg0'] == 'goal8' and info['gg1'] == 'goal5' \
            and info['gg2'] == 'goal0' and info['gg3'] == 'goal0' \
            and info['gv0'] is True and info['gv3'] is True \
            and info['gv4'] is False and isinstance(info['gx0'], int) \
            and info['v1'] == '12.3k' \
            and info['v4'] == '78%', \
            f'{face}: bad checklist: {info}'
    if face == 'argyle':
        assert info['steps'] == '12.3k' and info['bpm'] == '72' \
            and info['batt'] == '78%' and info['date'] == 'SAT 18', \
            f'{face}: bad complications: {info}'
    if face == 'wicker':
        assert info['steps'] == '12.3k' and info['kcal'] == '486' \
            and info['batt'] == '78%' and info['date'] == 'SAT 18', \
            f'{face}: bad complications: {info}'
    if face == 'reptile':
        # steps 12345/10000 caps at 1 -> 225+270=135; battery 78% ->
        # 225+210.6=436->76; date 18 -> (17/30)*270+225=378->18
        assert info['srot'] == 135 and info['brot'] == 76 \
            and info['drot'] == 18, f'{face}: bad registers: {info}'

    assert 'forward_input:middle_short_press_release' in log, \
        f'{face}: unassigned button not forwarded'
    assert responses['button2'].get('action') == \
        {'type': 'open_app', 'node_name': 'stopwatchApp',
         'class': 'watch_app'}, f'{face}: button_assignments ignored'
    assert 'forward_input:top_hold' not in log, \
        f'{face}: assigned button must not be forwarded'

    # wrist flick: relative swing away, no re-telling until restored
    assert responses['flick'].get('move') == \
        {'h': 360, 'm': -360, 'is_relative': True}, f'{face}: no flick move'
    assert 'disable_time_telling' in log, \
        f'{face}: flick must disable time telling'
    assert 'start_timer:hands:2200' in log, f'{face}: no hands restore timer'
    assert 'move' not in responses['timetell2'], \
        f'{face}: time telling fought the parked hands'
    assert responses['unflick'].get('move') == \
        {'h': 123, 'm': 231, 'is_relative': False}, \
        f'{face}: hands not restored after flick'
    assert 'stop_timer:tick' in log, f'{face}: timer not stopped on hide'
    assert 'draw' not in responses['straytick'], \
        f'{face}: drew while invisible'
    print(f'{face}: OK ({len(layout)} nodes, '
          f'{len(needed)} placeholders: {sorted(needed)})')


def main():
    faces = sys.argv[1:] or FACES
    for face in faces:
        check_face(face)
    print('all faces pass')


if __name__ == '__main__':
    main()
