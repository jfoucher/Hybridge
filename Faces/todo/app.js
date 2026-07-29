/*
 * Todo — today's list.  The checkboxes tick themselves as the goals
 * are met: steps vs daily goal, calories vs 400 (or the configured
 * goal), 30 active minutes, and a charged battery.
 */
return {
	"node_name": '',
	"manifest": { "timers": ['tick', 'hands'] },
	"persist": {},
	"config": {},

	"visible": false,
	"handled_start_app_seq": null,
	"minutes": 0,

	"init": function () {},

	"is_button": function (event) {
		var t = event.type || '';
		return t.indexOf('top_') === 0
			|| t.indexOf('middle_') === 0
			|| t.indexOf('bottom_') === 0;
	},

	"fmt_steps": function (n) {
		n = n || 0;
		if (n >= 10000)
			return (Math.floor(n / 100) / 10) + 'k';
		return '' + n;
	},

	// The firmware text node only has its built-in font.  Compose the
	// configurable walking target from Bradley Hand glyph images instead,
	// matching the label baked into the Todo background.
	"goal_glyph_name": function (ch) {
		return ch === '.' ? 'goalDot' : 'goal' + ch;
	},

	"goal_glyph_advance": function (ch) {
		if (ch === '.') return 4;
		if (ch === '1') return 8;
		if (ch === '0' || ch === '8' || ch === '9') return 9;
		return 10;
	},

	"fill_goal_glyphs": function (value, info) {
		value = value.slice(0, 5);
		var pen = 90;
		var cell = 16;
		for (var i = 0; i < 5; i++) {
			if (i < value.length) {
				var ch = value.charAt(i);
				var advance = this.goal_glyph_advance(ch);
				info['gg' + i] = this.goal_glyph_name(ch);
				info['gx' + i] = Math.floor(pen - (cell - advance) / 2);
				info['gv' + i] = true;
				pen += advance;
			} else {
				// Invisible nodes still need a valid image on this firmware.
				info['gg' + i] = 'goal0';
				info['gx' + i] = 0;
				info['gv' + i] = false;
			}
		}
	},

	"compute": function () {
		var c = (typeof get_common === 'function') ? get_common() : common;
		var goal_s = (c.daily_goal && c.daily_goal.steps) || 6000;
		var goal_k = (c.daily_goal && c.daily_goal.calories) || 400;
		var steps = c.step_count || 0;
		var kcal = c.calories || 0;
		var act = c.active_minutes || 0;
		var soc = c.battery_soc || 0;
		var info = {
			"json_file": 'todo_layout',
			"c1": steps >= goal_s ? 'boxck' : 'box',
			"c2": kcal >= goal_k ? 'boxck' : 'box',
			"c3": act >= 30 ? 'boxck' : 'box',
			"c4": soc >= 80 ? 'boxck' : 'box',
			"v1": this.fmt_steps(steps),
			"v2": '' + kcal,
			"v3": act + 'm',
			"v4": soc + '%'
		};
		this.fill_goal_glyphs(this.fmt_steps(goal_s), info);
		return info;
	},

	"draw": function (response, full) {
		response.draw = { "update_type": full ? 'du4' : 'gu4' };
		response.draw[this.node_name] = {
			"layout_function": 'layout_parser_json',
			"layout_info": this.compute()
		};
	},

	"move_hands": function (response) {
		if (typeof enable_time_telling !== 'function')
			return;
		var pos = enable_time_telling();
		this.telling = true;
		if (pos)
			response.move = {
				"h": pos.hour_pos,
				"m": pos.minute_pos,
				"is_relative": false
			};
	},

	// The phone can push {"<this app>._.config.start_app": name,
	// "<this app>._.config.start_app_seq": n} to launch another app
	// (e.g. workoutApp) without a physical button, using the same
	// open_app action the button_assignments path below already uses.
	// start_app_seq is a value the phone bumps on every push: without
	// it, this.config still reads the last-launched name on every
	// later common_update (a battery tick, a step-count change, ...)
	// and would re-open that app on each one. Only a *new* seq is a
	// fresh request; gated on visible since launching another app only
	// makes sense from the face that is actually on screen.
	"check_start_app": function (response) {
		if (!this.visible)
			return;
		var cfg = this.config || {};
		var target = cfg.start_app;
		var seq = cfg.start_app_seq;
		if (is_empty_string(target) || seq === this.handled_start_app_seq)
			return;
		this.handled_start_app_seq = seq;
		response.action = { "type": 'open_app', "node_name": target, "class": 'watch_app' };
	},

	"handler": function (event, response) {
		var t = event.type;
		if (t === 'system_state_update' && event.de) {
			if (event.le === 'visible') {
				this.visible = true;
				this.minutes = 0;
				this.move_hands(response);
				this.draw(response, true);
				start_timer(this.node_name, 'tick', 60000);
			} else {
				this.visible = false;
				stop_timer(this.node_name, 'tick');
			}
		} else if (t === 'ui_boot_up_done') {
			// reclaim the watchface slot after a reboot
			response.action = { "type": 'go_visible', "class": 'home' };
		} else if (t === 'timer_expired') {
			if (is_this_timer_expired(event, this.node_name, 'hands')) {
				// wrist flick over: put the hands back on time
				this.move_hands(response);
			}
			if (this.visible
				&& is_this_timer_expired(event, this.node_name, 'tick')) {
				this.minutes += 1;
				// full refresh every 15 min keeps ghosting down
				this.draw(response, (this.minutes % 15) === 0);
				start_timer(this.node_name, 'tick', 60000);
			}
		} else if (t === 'time_telling_update') {
			if (this.telling !== false)
				this.move_hands(response);
			if (this.visible)
				this.draw(response, false);
		} else if (t === 'common_update' || t === 'display_data_updated' || t === 'node_config_update') {
			this.check_start_app(response);
			if (this.visible)
				this.draw(response, false);
		} else if (t === 'flick_away') {
			// wrist flick: swing the hands out of the way with a full
			// relative turn, then the 'hands' timer puts them back
			// (same mechanic as the GB open-source watchface)
			if (typeof disable_time_telling === 'function')
				disable_time_telling();
			this.telling = false;
			response.move = { "h": 360, "m": -360, "is_relative": true };
			start_timer(this.node_name, 'hands', 2200);
		} else if (event.is_button_event || this.is_button(event)) {
			// per-face shortcuts if configured (GB button_assignments),
			// otherwise hand the event back to the system so the
			// master._.config.buttons shortcuts keep working
			var a = this.config && this.config.button_assignments;
			var handled = false;
			for (var i in a) {
				if (a[i] && a[i].button_evt === t) {
					response.action = {
						"type": 'open_app',
						"node_name": a[i].name,
						"class": 'watch_app'
					};
					handled = true;
				}
			}
			if (!handled && typeof forward_input === 'function')
				forward_input(event, [], {});
		}
	}
};
