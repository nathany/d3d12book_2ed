// The port's growing grab-bag of small helpers — the book's `d3dUtil.h` + `d3dx12.h`
// conveniences, added the first time a pattern repeats (per the porting guide: don't port
// d3dx12.h, grow this organically).
package common

import "base:runtime"
import "core:fmt"
import "core:os"
import win "core:sys/windows"
import d3d12 "vendor:directx/d3d12"

// Fatal-error reporting, both channels (port convention — see the guides): stderr for
// consoles/CI, a message box for a human running the windowed app. (Duplicated from
// APPENDIX_A, which stays self-contained by design.)
report_error :: proc(what: string) {
	fmt.eprintfln("fatal error: %s", what)
	text := win.utf8_to_wstring(what)
	win.MessageBoxW(nil, text, win.L("Error"), win.MB_OK | win.MB_ICONERROR)
}

// C++: ThrowIfFailed(hr) + the DxException catch in WinMain, fused. The guide's day-one
// `hr_panic`: #caller_location gives free file:line in the report — nicer than the C++.
hr_panic :: proc(hr: d3d12.HRESULT, what: string, loc := #caller_location) {
	if hr >= 0 {
		return
	}
	report_error(fmt.tprintf("%s failed with HRESULT 0x%8x at %v", what, u32(hr), loc))
	os.exit(1)
}

// C++: CD3DX12_RESOURCE_BARRIER::Transition(resource, before, after).
// Plain data — the barrier borrows the resource pointer (no ref counting), same as C++.
transition_barrier :: proc(
	resource: ^d3d12.IResource,
	before, after: d3d12.RESOURCE_STATES,
) -> d3d12.RESOURCE_BARRIER {
	barrier := d3d12.RESOURCE_BARRIER {
		Type  = .TRANSITION,
		Flags = {},
	}
	barrier.Transition = {
		pResource   = resource,
		StateBefore = before,
		StateAfter  = after,
		Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
	}
	return barrier
}

// Convenience for COM out-params: `ptr(&obj)` in place of C++ IID_PPV_ARGS's second half.
ptr :: proc(p: ^^$T) -> ^rawptr {
	return (^rawptr)(p)
}

// For "system" callbacks (WndProc, InfoQueue1) that need Odin features (fmt, allocators):
// they have no context; restore the default one.
default_context :: proc "contextless" () -> runtime.Context {
	return runtime.default_context()
}
