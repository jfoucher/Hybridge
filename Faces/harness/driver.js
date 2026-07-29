/* Drives a wrapped face app (global `app`) through its lifecycle and
 * prints one JSON line per checkpoint for test.py to assert on. */
function fire(name, event) {
	var response = {};
	app.handler(event, response);
	print('RESP ' + name + ' ' + JSON.stringify(response));
	return response;
}

app.init();

fire('boot', { type: 'ui_boot_up_done' });
fire('visible', { type: 'system_state_update', de: true, le: 'visible' });
fire('tick', { type: 'timer_expired', timer_name: 'tick' });
fire('common', { type: 'common_update' });
fire('timetell', { type: 'time_telling_update' });

/* weather data lands (the shape the companion app pushes) */
common.weatherInfo = {
	alive: get_unix_time() + 3600, unit: 'c', temp: 21,
	cond_id: 3, rain: 30, uv: 5
};
common.hr_bpm = 72;
common.step_count = 12345;
fire('data', { type: 'display_data_updated' });

/* 15th minute forces a full du4 redraw */
for (var i = 0; i < 14; i++)
	fire('tick' + (2 + i), { type: 'timer_expired', timer_name: 'tick' });

/* wrist flick: hands swing away, then the hands timer restores them;
 * a time_telling_update in between must not fight the parked hands */
fire('flick', { type: 'flick_away' });
fire('timetell2', { type: 'time_telling_update' });
fire('unflick', { type: 'timer_expired', timer_name: 'hands' });

/* buttons: unassigned -> forwarded; assigned -> open_app action */
fire('button', { type: 'middle_short_press_release', is_button_event: true });
app.config.button_assignments = [
	{ button_evt: 'top_hold', name: 'stopwatchApp' }
];
fire('button2', { type: 'top_hold', is_button_event: true });

fire('hidden', { type: 'system_state_update', de: true, le: 'hidden' });
/* invisible: a stray timer must not draw */
fire('straytick', { type: 'timer_expired', timer_name: 'tick' });

print('LOG ' + JSON.stringify(__log));
