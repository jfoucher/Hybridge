/*
 * Horizon — a sun clock.  The ring is one whole day cut by the
 * horizon line: the top half is daylight (sunrise at 9 o'clock,
 * solar noon at 12, sunset at 3), the bottom half is night.  The
 * orb rides the ring at today's real sun (or moon) position, the
 * bright part of the ring is the daylight already spent, and the
 * middle line says how much of it is left.
 *
 * Sunrise/sunset come from the standard solar-position algorithm
 * (same numbers as the moonphase app's SunCalc port, ~1 min), fed by
 * config.position — push it from the phone with
 *   horizonFace._.config.position = {"lat": .., "lon": ..}
 */
return {
	"node_name": '',
	"manifest": { "timers": ['tick', 'hands'] },
	"persist": {},
	"config": {
		// Paris; the watch has no GPS, so this is all we can assume
		"position": { "lat": 48.8566, "lon": 2.3522 }
	},

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

	"dows": ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'],
	"mons": ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
		'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'],

	"RAD": Math.PI / 180,

	// Sakamoto's method; m is 1..12, returns 0=Sunday
	"day_of_week": function (y, m, d) {
		var t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
		if (m < 3)
			y -= 1;
		return (y + Math.floor(y / 4) - Math.floor(y / 100)
			+ Math.floor(y / 400) + t[m - 1] + d) % 7;
	},

	"jdn": function (y, m, d) {
		var a = Math.floor((14 - m) / 12);
		var y2 = y + 4800 - a;
		var m2 = m + 12 * a - 3;
		return d + Math.floor((153 * m2 + 2) / 5) + 365 * y2
			+ Math.floor(y2 / 4) - Math.floor(y2 / 100)
			+ Math.floor(y2 / 400) - 32045;
	},

	"sin": function (deg) { return Math.sin(deg * this.RAD); },
	"cos": function (deg) { return Math.cos(deg * this.RAD); },

	"local_minutes": function (c) {
		var mins = Math.floor(get_unix_time() / 60)
			+ (c.time_zone_local || 0);
		mins = mins % 1440;
		if (mins < 0) mins += 1440;
		return mins;
	},

	/*
	 * Sunrise/sunset for today, in local decimal hours (they can fall
	 * slightly outside 0..24 near the solstices — callers keep the raw
	 * value for the day-fraction maths and only wrap for display).
	 * Returns {polar: -1|1} inside the polar circles, where the sun
	 * does not cross the horizon at all.
	 */
	"sun_times": function (c) {
		var pos = (this.config && this.config.position) || {};
		var lat = (typeof pos.lat === 'number') ? pos.lat : 48.8566;
		var lon = (typeof pos.lon === 'number') ? pos.lon : 2.3522;
		var jd = this.jdn(c.year || 2026, (c.month || 0) + 1, c.date || 1);

		var js = (jd - 2451545 + 0.0008) - lon / 360;
		var M = (357.5291 + 0.98560028 * js) % 360;
		var C = 1.9148 * this.sin(M) + 0.02 * this.sin(2 * M)
			+ 0.0003 * this.sin(3 * M);
		var lam = (M + C + 102.9372 + 180) % 360;
		var jt = js + 0.0053 * this.sin(M) - 0.0069 * this.sin(2 * lam);
		var dec = Math.asin(this.sin(lam) * this.sin(23.44));

		// hours between the J2000 epoch and local midnight tonight
		var base = (2451545 - (jd - 0.5)) * 24
			+ (c.time_zone_local || 0) / 60;
		var noon = base + jt * 24;

		var cosw = (this.sin(-0.833) - this.sin(lat) * Math.sin(dec))
			/ (this.cos(lat) * Math.cos(dec));
		if (cosw >= 1)
			return { "polar": -1, "noon": noon };
		if (cosw <= -1)
			return { "polar": 1, "noon": noon };
		var w = Math.acos(cosw) / this.RAD / 15;   // half-day, in hours
		return { "rise": noon - w, "set": noon + w, "noon": noon };
	},

	"hhmm": function (h) {
		h = h % 24;
		if (h < 0) h += 24;
		var hh = Math.floor(h);
		var mm = Math.round((h - hh) * 60);
		if (mm === 60) { mm = 0; hh = (hh + 1) % 24; }
		return (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm;
	},

	// a duration in hours as "6h12"
	"span": function (h) {
		if (h < 0) h = 0;
		var hh = Math.floor(h);
		var mm = Math.round((h - hh) * 60);
		if (mm === 60) { mm = 0; hh += 1; }
		return hh + 'h' + (mm < 10 ? '0' : '') + mm;
	},

	// orb position on the ring; angle 0 = noon at the top, clockwise
	"orb_xy": function (angle, out) {
		out.ox = Math.round(120 + 88 * this.sin(angle)) - 9;
		out.oy = Math.round(120 - 88 * this.cos(angle)) - 9;
	},

	"compute": function () {
		var c = (typeof get_common === 'function') ? get_common() : common;
		var t = this.local_minutes(c) / 60;
		var s = this.sun_times(c);
		var dow = this.day_of_week(c.year || 2026, (c.month || 0) + 1,
			c.date || 1);
		var info = {
			"json_file": 'horizon_layout',
			"date": this.dows[dow] + ' ' + (c.date || 1) + ' '
				+ this.mons[c.month || 0],
			"s1": 0, "e1": 0, "s2": 0, "e2": 0
		};

		if (s.polar) {
			// no sunrise or sunset here today: park the orb at the
			// sun's clock position and say so
			var up = s.polar > 0;
			info.rise = '--:--';
			info.set = '--:--';
			info.orb = up ? 'sunorb' : 'moonorb';
			info.big = up ? '24h' : '0h';
			info.cap = up ? 'MIDNIGHT SUN' : 'POLAR NIGHT';
			this.orb_xy((t / 24) * 360 + 180, info);
			return info;
		}

		info.rise = this.hhmm(s.rise);
		info.set = this.hhmm(s.set);

		// hours since this morning's sunrise, wrapped into 0..24 — so
		// the maths holds even where daylight straddles local midnight
		var len = s.set - s.rise;
		var since = (t - s.rise) % 24;
		if (since < 0) since += 24;

		if (since < len) {
			// daylight: sunrise 270deg -> sunset 90deg over the top
			var p = since / len;
			var a = 270 + p * 180;
			this.orb_xy(a, info);
			info.orb = 'sunorb';
			info.big = this.span(len - since);
			info.cap = 'OF DAYLIGHT LEFT';
			info.s1 = 270;
			info.e1 = Math.min(Math.round(a), 360);
			if (a > 360) {
				info.s2 = 0;
				info.e2 = Math.round(a - 360);
			}
		} else {
			// night: sunset 90deg -> sunrise 270deg under the horizon
			var night = 24 - len;
			var dark = since - len;
			var q = night > 0 ? dark / night : 0;
			this.orb_xy(90 + q * 180, info);
			info.orb = 'moonorb';
			info.big = this.span(night - dark);
			info.cap = 'UNTIL SUNRISE';
			info.s1 = 90;
			info.e1 = Math.round(90 + q * 180);
		}
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
