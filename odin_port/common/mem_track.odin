// Odin-side leak detection via core:mem's Tracking_Allocator — the Odin analogue of the
// C++ demos' CRT debug-heap leak check. Debug builds (`-debug`) only; release builds get
// the plain allocators back untouched.
//
// Usage, in every demo main:
//
//     context = common.mem_track_init()   // FIRST line — before any allocation
//     ...
//     common.mem_track_report()           // right before os.exit (os.exit skips defers!)
//
// What it covers:
//  - context.allocator: every new/make/map/[dynamic] not explicitly freed is reported at
//    exit with its allocation site ([odin-leak] lines on stderr; silent when clean).
//  - context.temp_allocator: also wrapped. The temp arena answers .Free_All to
//    Query_Features, so tracking_allocator_init sets clear_on_free_all and the per-frame
//    free_all in d3d_app_run empties the tracker's map each frame — near-zero steady-state
//    overhead. Its value isn't leak reports (temp "leaks" are reclaimed wholesale) but the
//    bad-free panic below catching cross-allocator mistakes, e.g. delete() of a
//    temp-allocated slice.
//  - Bad frees (double free, free of a borrowed/foreign pointer) PANIC at the offending
//    call site — core:mem's default callback — which is exactly the trap we want sprung
//    early after the C7_Waves borrowed-vertex-buffer episode.
//
// The context returned by mem_track_init also reaches the Win32/ImGui callbacks: they
// restore `app_context` (captured by d3d_app_init) rather than runtime.default_context(),
// so allocations on those paths are tracked too. The only exception is the D3D12 info-queue
// callback, which can fire on driver threads — see register_debug_callback.
//
// (The C1–C3 test packages need none of this: `odin test` wraps every test in its own
// tracking allocator already.)
package common

import "base:runtime"
import "core:fmt"
import "core:mem"

// Package globals, not locals in the demo's main: the trackers must be reachable from
// mem_track_report without every demo threading pointers through.
@(private = "file")
g_track: mem.Tracking_Allocator
@(private = "file")
g_temp_track: mem.Tracking_Allocator

// Returns main's context with both allocators wrapped in tracking allocators (debug
// builds). Assign it: `context = common.mem_track_init()` — a callee can't mutate its
// caller's context, so the demo's main must do the assignment itself for the tracked
// context to propagate to everything below it.
mem_track_init :: proc() -> runtime.Context {
	ctx := context
	when ODIN_DEBUG {
		// Called while ctx.allocator is still the raw heap allocator, so the trackers'
		// own bookkeeping (internals_allocator) is untracked — tracking it would deadlock
		// on the tracker's non-reentrant mutex.
		mem.tracking_allocator_init(&g_track, ctx.allocator)
		mem.tracking_allocator_init(&g_temp_track, ctx.temp_allocator)
		ctx.allocator = mem.tracking_allocator(&g_track)
		ctx.temp_allocator = mem.tracking_allocator(&g_temp_track)
	}
	return ctx
}

// Report leaks to stderr (silent when clean, matching the D3D leak report's convention).
// Call after d3d_app_shutdown, before os.exit.
mem_track_report :: proc() {
	when ODIN_DEBUG {
		for _, entry in g_track.allocation_map {
			fmt.eprintfln("[odin-leak] %v bytes at %v", entry.size, entry.location)
		}
		// bad_free_array stays empty — the default callback panics instead (see header).
		mem.tracking_allocator_destroy(&g_track)
		mem.tracking_allocator_destroy(&g_temp_track)
	}
}
