/* Engine-global mocks for running face app.js under the desktop jerry
 * CLI (es5.1).  Loaded before the wrapped app source. */
var __log = [];

var common = {
	year: 2026, month: 6, date: 18,          /* month is 0-based: July */
	time_zone_local: 120,
	step_count: 7234,
	calories: 486,
	battery_soc: 78,
	active_minutes: 42,
	hr_bpm: 0,
	daily_goal: { steps: 10000 }
};

function get_common() { return common; }
function get_unix_time() { return 1784732400; }
function enable_time_telling() { return { hour_pos: 123, minute_pos: 231 }; }
function disable_time_telling() { __log.push('disable_time_telling'); }
function start_timer(node, name, ms) { __log.push('start_timer:' + name + ':' + ms); }
function stop_timer(node, name) { __log.push('stop_timer:' + name); }
function is_this_timer_expired(event, node, name) { return event.timer_name === name; }
function forward_input(event, a, b) { __log.push('forward_input:' + event.type); }
function req_data(node, key, timeout, flag) { __log.push('req_data:' + key); }
function localization_snprintf() { return ''; }
function is_button_event(e) { return false; }
function deep_fill(a, b) { return a; }
function is_empty_string(s) { return !s || s === ''; }
