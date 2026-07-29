/*
 * Almanac — the calendar questions a watch should answer without a
 * phone: what date is Thursday, which ISO week is this, how far into
 * the year are we.  A Monday-to-Sunday strip with today boxed, the
 * week number, the day of the year, and a rim gauge running from
 * 1 January (top) all the way round.
 *
 * Dates are done in Julian day numbers, so the strip crosses month
 * and year ends without any month-length tables.
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

	"mons": ['JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE',
		'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER'],

	// strip column centres, Monday .. Sunday
	"cols": [33, 62, 91, 120, 149, 178, 207],

	"jdn": function (y, m, d) {
		var a = Math.floor((14 - m) / 12);
		var y2 = y + 4800 - a;
		var m2 = m + 12 * a - 3;
		return d + Math.floor((153 * m2 + 2) / 5) + 365 * y2
			+ Math.floor(y2 / 4) - Math.floor(y2 / 100)
			+ Math.floor(y2 / 400) - 32045;
	},

	// Fliegel & Van Flandern, the other way round: JDN -> day of month
	"day_of": function (jdn) {
		var a = jdn + 32044;
		var b = Math.floor((4 * a + 3) / 146097);
		var c = a - Math.floor(146097 * b / 4);
		var d = Math.floor((4 * c + 3) / 1461);
		var e = c - Math.floor(1461 * d / 4);
		var m = Math.floor((5 * e + 2) / 153);
		return e - Math.floor((153 * m + 2) / 5) + 1;
	},

	// ISO-8601: how many weeks the given year holds (52 or 53)
	"weeks_in_year": function (y) {
		function p(n) {
			return (n + Math.floor(n / 4) - Math.floor(n / 100)
				+ Math.floor(n / 400)) % 7;
		}
		return (p(y) === 4 || p(y - 1) === 3) ? 53 : 52;
	},

	"compute": function () {
		var c = (typeof get_common === 'function') ? get_common() : common;
		var y = c.year || 2026;
		var m = (c.month || 0) + 1;
		var d = c.date || 1;

		var jd = this.jdn(y, m, d);
		var jan1 = this.jdn(y, 1, 1);
		var ylen = this.jdn(y + 1, 1, 1) - jan1;
		var doy = jd - jan1 + 1;
		// JDN 0 was a Monday, so this is the ISO weekday, 1=Mon..7=Sun
		var iso = (jd % 7) + 1;

		var week = Math.floor((doy - iso + 10) / 7);
		if (week < 1)
			week = this.weeks_in_year(y - 1);
		else if (week > this.weeks_in_year(y))
			week = 1;

		var monday = jd - (iso - 1);
		var info = {
			"json_file": 'almanac_layout',
			"month": this.mons[c.month || 0] + ' ' + y,
			"week": 'WEEK ' + week,
			"doy": 'DAY ' + doy + ' OF ' + ylen,
			"yarc": Math.max(2, Math.round(doy / ylen * 360)),
			// the box goes round today's column
			"mx": this.cols[iso - 1] - 13
		};
		for (var i = 0; i < 7; i++) {
			var n = this.day_of(monday + i);
			// two characters wide either way, so the fixed column
			// positions keep the strip lined up
			info['d' + i] = (n < 10 ? ' ' : '') + n;
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
