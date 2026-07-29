/*
 * Meteo — weather watchface: condition icon, big temperature, rain
 * chance and UV index, step count, battery ring at the rim.  Weather
 * comes from the phone via the req_data("weatherInfo") round-trip the
 * companion app answers; slots show "--" until data arrives.
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

	"icon_for": function (cond_id) {
		var map = {
			"0": 'wxClearDay', "1": 'wxClearNight', "2": 'wxCloudy',
			"3": 'wxPartDay', "4": 'wxPartNight', "5": 'wxRain',
			"6": 'wxSnow', "7": 'wxSnow', "8": 'wxStorm', "10": 'wxWind'
		};
		return map['' + cond_id] || 'wxNone';
	},

	"compute": function () {
		var c = (typeof get_common === 'function') ? get_common() : common;
		var w = this.weather(c);
		var soc = c.battery_soc || 0;
		return {
			"json_file": 'meteo_layout',
			"wicon": this.icon_for(w ? w.cond_id : -1),
			"temp": w
				? Math.round(w.temp) + (w.unit === 'f' ? 'F' : 'C')
				: '--',
			"rain": (w && typeof w.rain === 'number') ? w.rain + '%' : '--',
			"uv": (w && typeof w.uv === 'number') ? '' + w.uv : '--',
			"steps": this.fmt_steps(c.step_count),
			"barc": Math.max(2, Math.round(soc * 3.6))
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
				// refresh weather every 5 minutes while visible
				if ((this.minutes % 5) === 0)
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
