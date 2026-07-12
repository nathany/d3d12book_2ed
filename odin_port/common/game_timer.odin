// Port of `Common/GameTimer.cpp` (Frank Luna).
//
// QueryPerformanceCounter is bound in core:sys/windows, so unlike the Rust port (which
// wrapped std::time::Instant) this is the book's arithmetic verbatim: raw i64 counts and
// a seconds-per-count factor.
package common

import win "core:sys/windows"

Game_Timer :: struct {
	seconds_per_count: f64,
	delta_time:        f64,
	base_time:         i64,
	paused_time:       i64,
	stop_time:         i64,
	prev_time:         i64,
	curr_time:         i64,
	stopped:           bool,
}

game_timer_init :: proc(t: ^Game_Timer) {
	counts_per_sec: win.LARGE_INTEGER
	win.QueryPerformanceFrequency(&counts_per_sec)
	t.seconds_per_count = 1.0 / f64(counts_per_sec)
	t.delta_time = -1.0
}

// Returns the total time elapsed since reset() was called, NOT counting any
// time when the clock is stopped.
game_timer_total_time :: proc(t: ^Game_Timer) -> f32 {
	// If we are stopped, do not count the time that has passed since we stopped.
	// Moreover, subtract accumulated paused time from (stop - base):
	//
	//                     |<--paused time-->|
	// ----*---------------*-----------------*------------*------------*------> time
	//  base_time       stop_time        start_time    stop_time    curr_time
	if t.stopped {
		return f32(f64((t.stop_time - t.paused_time) - t.base_time) * t.seconds_per_count)
	}
	return f32(f64((t.curr_time - t.paused_time) - t.base_time) * t.seconds_per_count)
}

game_timer_delta_time :: proc(t: ^Game_Timer) -> f32 {
	return f32(t.delta_time)
}

game_timer_reset :: proc(t: ^Game_Timer) {
	curr_time: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&curr_time)

	t.base_time = i64(curr_time)
	t.prev_time = i64(curr_time)
	t.stop_time = 0
	t.stopped = false
}

game_timer_start :: proc(t: ^Game_Timer) {
	start_time: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&start_time)

	// Accumulate the time elapsed between stop and start pairs.
	if t.stopped {
		t.paused_time += i64(start_time) - t.stop_time
		t.prev_time = i64(start_time)
		t.stop_time = 0
		t.stopped = false
	}
}

game_timer_stop :: proc(t: ^Game_Timer) {
	if !t.stopped {
		curr_time: win.LARGE_INTEGER
		win.QueryPerformanceCounter(&curr_time)

		t.stop_time = i64(curr_time)
		t.stopped = true
	}
}

game_timer_tick :: proc(t: ^Game_Timer) {
	if t.stopped {
		t.delta_time = 0
		return
	}

	curr_time: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&curr_time)
	t.curr_time = i64(curr_time)

	// Time difference between this frame and the previous.
	t.delta_time = f64(t.curr_time - t.prev_time) * t.seconds_per_count

	// Prepare for next frame.
	t.prev_time = t.curr_time

	// Force nonnegative. The DXSDK's CDXUTTimer mentions that if the processor goes into a
	// power save mode or we get shuffled to another processor, delta can be negative.
	if t.delta_time < 0 {
		t.delta_time = 0
	}
}
