/*
 * Regence - a silver-guilloche calendar in the spirit of a Breguet
 * Classique.  Two central retrograde hands (month upper-left, date
 * across the bottom), a weekday sub-dial on the right, a power-reserve
 * sector between 8 and 9 and a moon-phase aperture upper-right.  All
 * scales are baked into the background; the four hands are svg_image
 * needles and the moon is a sprite swap.
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

	// Sakamoto's method; m is 1..12, returns 0=Sunday
	"day_of_week": function (y, m, d) {
		var t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
		if (m < 3)
			y -= 1;
		return (y + Math.floor(y / 4) - Math.floor(y / 100)
			+ Math.floor(y / 400) + t[m - 1] + d) % 7;
	},

	// bosom-moon phase sprite: pick one of the pre-rendered disc-rotation
	// frames from the moon's age (frame 0 = new .. 8 = full .. wraps)
	"moon_frame": function (y, m, d) {
		var a = Math.floor((14 - m) / 12);
		var y2 = y + 4800 - a;
		var m2 = m + 12 * a - 3;
		var jdn = d + Math.floor((153 * m2 + 2) / 5) + 365 * y2
			+ Math.floor(y2 / 4) - Math.floor(y2 / 100)
			+ Math.floor(y2 / 400) - 32045;
		var age = (jdn - 2451550) % 29.530588;
		if (age < 0) age += 29.530588;
		var n = 30;
		var i = Math.floor((age / 29.530588) * n) % n;
		return 'moon' + (i < 10 ? '0' : '') + i;
	},

	// --- retrograde scale angle maps (must match gen_assets.py) ---
	// month: ~120 deg fan pivoting at the top-left, Jan at 9:15 .. Dec at 12
	"month_angle": function (m0) {
		return 199 - m0 * (121.0 / 11.0);
	},
	// date: big 306 deg retrograde ring about the lower sub-dial
	// (centre 120,177), 1 up-right sweeping clockwise round to 31 up-left;
	// the 54 deg gap at the top keeps 1 and 31 clear of the hands hub
	"date_angle": function (d) {
		return 27 + (d - 1) * (306.0 / 30.0);
	},
	// weekday sub-dial on the right: seven days around the whole circle
	"dow_angle": function (w) {
		return w * (360.0 / 7.0);
	},
	// power reserve between 7 and 8: battery across a 45 deg sector
	// centred on that gauge's own 12 (must match gen_assets.py)
	"pwr_angle": function (soc) {
		return (soc / 100.0 - 0.5) * 45.0;
	},

	"compute": function () {
		var c = (typeof get_common === 'function') ? get_common() : common;
		var y = c.year || 2026;
		var m = (c.month || 0) + 1;
		var d = c.date || 1;
		var w = this.day_of_week(y, m, d);
		return {
			"json_file": 'regence_layout',
			"mon": this.month_angle(c.month || 0),
			"dat": this.date_angle(d),
			"dow": this.dow_angle(w),
			"pwr": this.pwr_angle(c.battery_soc || 0),
			"moon": this.moon_frame(y, m, d)
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

	// The phone can push {"<this app>._.config.start_app": name, ...seq}
	// to launch another app without a physical button (see glass/app.js).
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
			if (typeof disable_time_telling === 'function')
				disable_time_telling();
			this.telling = false;
			response.move = { "h": 360, "m": -360, "is_relative": true };
			start_timer(this.node_name, 'hands', 2200);
		} else if (event.is_button_event || this.is_button(event)) {
			// per-face shortcuts if configured, otherwise hand the event
			// back to the system so master._.config.buttons still works
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
