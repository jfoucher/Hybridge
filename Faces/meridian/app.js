/*
 * Meridian — a world timer.  Local time and date up top (the hands
 * are good for "about ten past", not for booking a call), then three
 * zones with their own clock, a +1/-1 mark when the date over there
 * is not today's, and a sun or moon token so you can see at a glance
 * whether it is a decent hour to ring.
 *
 * Zones come from config, so they can be re-pointed from the phone:
 *   meridianFace._.config.zones =
 *     [{"name":"NYC","offset":-240}, ...]     offset = minutes from UTC
 */
return {
	"node_name": '',
	"manifest": { "timers": ['tick', 'hands'] },
	"persist": {},
	"config": {
		// offsets are minutes from UTC, standard time by default —
		// push new ones when the far end changes over to summer time
		"zones": [
			{ "name": 'UTC', "offset": 0 },
			{ "name": 'NYC', "offset": -240 },
			{ "name": 'TYO', "offset": 540 }
		]
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

	// Sakamoto's method; m is 1..12, returns 0=Sunday
	"day_of_week": function (y, m, d) {
		var t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
		if (m < 3)
			y -= 1;
		return (y + Math.floor(y / 4) - Math.floor(y / 100)
			+ Math.floor(y / 400) + t[m - 1] + d) % 7;
	},

	"hhmm": function (mins) {
		var m = mins % 1440;
		if (m < 0) m += 1440;
		var hh = Math.floor(m / 60);
		var mm = m % 60;
		return (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm;
	},

	// "UTC+2", "UTC-3:30" — how far the watch itself is from Greenwich
	"offset_label": function (mins) {
		var sign = mins < 0 ? '-' : '+';
		var a = Math.abs(mins);
		var h = Math.floor(a / 60);
		var m = a % 60;
		return 'UTC' + sign + h + (m ? ':' + (m < 10 ? '0' : '') + m : '');
	},

	"compute": function () {
		var c = (typeof get_common === 'function') ? get_common() : common;
		var utc = Math.floor(get_unix_time() / 60);
		var tz = c.time_zone_local || 0;
		var here = Math.floor((utc + tz) / 1440);     // local day number
		var dow = this.day_of_week(c.year || 2026, (c.month || 0) + 1,
			c.date || 1);
		var info = {
			"json_file": 'meridian_layout',
			"date": this.dows[dow] + ' ' + (c.date || 1) + ' '
				+ this.mons[c.month || 0] + '  ' + this.offset_label(tz),
			"ltime": this.hhmm(utc + tz)
		};

		var zones = (this.config && this.config.zones) || [];
		for (var i = 0; i < 3; i++) {
			var z = zones[i];
			var n = '' + (i + 1);
			if (!z || typeof z.offset !== 'number') {
				info['l' + n] = '';
				info['t' + n] = '';
				info['i' + n] = 'dnone';
				continue;
			}
			var mins = utc + z.offset;
			var hour = Math.floor((((mins % 1440) + 1440) % 1440) / 60);
			// which calendar day it is over there, relative to here
			var day = Math.floor(mins / 1440) - here;
			info['l' + n] = z.name || '';
			info['t' + n] = this.hhmm(mins)
				+ (day ? (day > 0 ? ' +1' : ' -1') : '');
			// working hours get a sun, the small hours a moon
			info['i' + n] = (hour >= 7 && hour < 19) ? 'dsun' : 'dmoon';
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
