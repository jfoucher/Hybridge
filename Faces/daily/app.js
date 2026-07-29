/*
 * Daily — typographic status board: weekday, big date and month up
 * top, then a ledger of steps / calories / active minutes / outside
 * temperature.  Temperature uses the weatherInfo round-trip answered
 * by the companion app and shows "--" until data arrives.
 */
return {
	"node_name": '',
	"manifest": { "timers": ['tick', 'hands'] },
	"persist": {},
	"config": {},

	"visible": false,
	"handled_start_app_seq": null,
	"minutes": 0,

	"dows": ['SUNDAY', 'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY',
		'FRIDAY', 'SATURDAY'],
	"months": ['JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE',
		'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER'],

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

	"ask_weather": function () {
		if (typeof req_data === 'function')
			req_data(this.node_name, '"weatherInfo":{}', 5000, true);
	},

	"weather": function (c) {
		var w = c.weatherInfo;
		if (w && typeof w.temp === 'number'
			&& (!w.alive || w.alive > Math.floor(get_unix_time())))
			return w;
		return null;
	},

	"compute": function () {
		var c = (typeof get_common === 'function') ? get_common() : common;
		var w = this.weather(c);
		var month = (c.month || 0) + 1;
		var dow = this.day_of_week(c.year || 2026, month, c.date || 1);
		return {
			"json_file": 'daily_layout',
			"dow": this.dows[dow],
			"date": '' + (c.date || 1),
			"month": this.months[month - 1],
			"steps": this.fmt_steps(c.step_count),
			"kcal": '' + (c.calories || 0),
			"act": (c.active_minutes || 0) + 'm',
			"temp": w
				? Math.round(w.temp) + (w.unit === 'f' ? 'F' : 'C')
				: '--'
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
				this.ask_weather();
			} else {
				this.visible = false;
				stop_timer(this.node_name, 'tick');
			}
		} else if (t === 'ui_boot_up_done') {
			response.action = { "type": 'go_visible', "class": 'home' };
		} else if (t === 'timer_expired') {
			if (is_this_timer_expired(event, this.node_name, 'hands')) {
				// wrist flick over: put the hands back on time
				this.move_hands(response);
			}
			if (this.visible
				&& is_this_timer_expired(event, this.node_name, 'tick')) {
				this.minutes += 1;
				this.draw(response, (this.minutes % 15) === 0);
				start_timer(this.node_name, 'tick', 60000);
				if ((this.minutes % 15) === 0)
					this.ask_weather();
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
