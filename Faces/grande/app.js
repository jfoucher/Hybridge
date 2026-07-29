/*
 * Grande — the grand complication.  Every datum the watch owns, told
 * the analog way: eight sub-dials around the physical hands (moon
 * aperture, weekday, date, heart rate, 24 hours, active minutes,
 * steps, month) plus calorie and power-reserve gauges on the rim.
 * Not a digit on the dial.
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

	// Sakamoto's method; m is 1..12, returns 0=Sunday
	"day_of_week": function (y, m, d) {
		var t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
		if (m < 3)
			y -= 1;
		return (y + Math.floor(y / 4) - Math.floor(y / 100)
			+ Math.floor(y / 400) + t[m - 1] + d) % 7;
	},

	// phase index 0..7 from days since the 2000-01-06 new moon
	"moon_phase": function (y, m, d) {
		var a = Math.floor((14 - m) / 12);
		var y2 = y + 4800 - a;
		var m2 = m + 12 * a - 3;
		var jdn = d + Math.floor((153 * m2 + 2) / 5) + 365 * y2
			+ Math.floor(y2 / 4) - Math.floor(y2 / 100)
			+ Math.floor(y2 / 400) - 32045;
		var age = (jdn - 2451550) % 29.530588;
		if (age < 0) age += 29.530588;
		return Math.round(age / 29.530588 * 8) % 8;
	},

	"local_minutes": function (c) {
		var mins = Math.floor(get_unix_time() / 60)
			+ (c.time_zone_local || 0);
		mins = mins % 1440;
		if (mins < 0) mins += 1440;
		return mins;
	},

	// 300-degree instrument scale: 0 -> -150deg, 1 -> +150deg
	"gauge": function (frac) {
		if (frac > 1) frac = 1;
		if (frac < 0) frac = 0;
		return (Math.round(-150 + frac * 300) + 360) % 360;
	},

	"compute": function () {
		var c = (typeof get_common === 'function') ? get_common() : common;
		var goal = (c.daily_goal && c.daily_goal.steps) || 6000;
		var month = (c.month || 0) + 1;
		var date = c.date || 1;
		var dow = this.day_of_week(c.year || 2026, month, date);
		var mins = this.local_minutes(c);
		var bpm = c.hr_bpm || 0;
		var soc = c.battery_soc || 0;
		var kcal = c.calories || 0;
		return {
			"json_file": 'grande_layout',
			"moon": 'phase' + this.moon_phase(c.year || 2026, month, date),
			"dowrot": Math.round(dow * 360 / 7),
			"daterot": Math.round((date - 1) * 360 / 31),
			"monrot": (month - 1) * 30,
			"rot24": Math.round(mins / 1440 * 360 + 180) % 360,
			"hrrot": this.gauge(bpm > 0 ? (bpm - 40) / 100 : 0),
			"actrot": this.gauge((c.active_minutes || 0) / 60),
			"steprot": this.gauge((c.step_count || 0) / goal),
			"karc": 30 + Math.max(1, Math.round(
				Math.min(kcal / 800, 1) * 60)),
			"barc": 210 + Math.max(1, Math.round(soc * 0.6))
		};
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
