//! Port of `Common/GameTimer.cpp` (Frank Luna).
//!
//! The book counts `QueryPerformanceCounter` ticks by hand; [`std::time::Instant`] wraps the
//! same counter on Windows, so the port keeps the book's *logic* (pause accumulation, the
//! stopped/running split in `total_time`) with `Instant`/`Duration` doing the arithmetic.
//! `mStopped`/`mStopTime` collapse into one `Option<Instant>`.

use std::time::{Duration, Instant};

pub struct GameTimer {
    base_time: Instant,
    paused_time: Duration,
    /// `Some(when)` while stopped — the book's `mStopped` + `mStopTime` pair.
    stop_time: Option<Instant>,
    prev_time: Instant,
    curr_time: Instant,
    delta_time: f64,
}

impl GameTimer {
    pub fn new() -> Self {
        let now = Instant::now();
        Self {
            base_time: now,
            paused_time: Duration::ZERO,
            stop_time: None,
            prev_time: now,
            curr_time: now,
            delta_time: 0.0,
        }
    }

    /// Returns the total time elapsed since `reset()` was called, NOT counting any
    /// time when the clock is stopped.
    pub fn total_time(&self) -> f32 {
        // If we are stopped, do not count the time that has passed since we stopped.
        // Moreover, subtract accumulated paused time from (stop - base).
        //
        //                     |<--paused time-->|
        // ----*---------------*-----------------*------------*------------*------> time
        //  base_time       stop_time        start_time    stop_time    curr_time
        let end = self.stop_time.unwrap_or(self.curr_time);
        ((end - self.base_time) - self.paused_time).as_secs_f32()
    }

    pub fn delta_time(&self) -> f32 {
        self.delta_time as f32
    }

    pub fn reset(&mut self) {
        let now = Instant::now();
        self.base_time = now;
        self.prev_time = now;
        self.stop_time = None;
    }

    pub fn start(&mut self) {
        // Accumulate the time elapsed between stop and start pairs.
        if let Some(stop_time) = self.stop_time.take() {
            let start_time = Instant::now();
            self.paused_time += start_time - stop_time;
            self.prev_time = start_time;
        }
    }

    pub fn stop(&mut self) {
        if self.stop_time.is_none() {
            self.stop_time = Some(Instant::now());
        }
    }

    pub fn tick(&mut self) {
        if self.stop_time.is_some() {
            self.delta_time = 0.0;
            return;
        }

        self.curr_time = Instant::now();

        // Time difference between this frame and the previous.
        self.delta_time = (self.curr_time - self.prev_time).as_secs_f64();

        // Prepare for next frame.
        self.prev_time = self.curr_time;

        // (The book clamps a possibly-negative delta here — a QueryPerformanceCounter
        // quirk across processors. `Instant` is monotonic, so no clamp is needed.)
    }
}

impl Default for GameTimer {
    fn default() -> Self {
        Self::new()
    }
}
