// Port of `Demos/C4_Init Direct3D` — chapter 4's initialization demo: clear the screen to
// LightSteelBlue every frame; FPS/mspf in the title bar; resize must survive repeated abuse
// (the chapter's real test — it exercises the OnResize/ResizeBuffers back-buffer trap).
//
// Build & run: odin run odin_port/C4_Init_Direct3D -debug     (debug layer + stderr log)
//
// NOT yet ported from the C++ demo: the ImGui overlay (Options panel, video-memory stats)
// and with it the CbvSrvUav descriptor heap — that's the next step (Capati/odin-imgui).
// The clear-and-present core below needs neither, nor any shader — no DXC involved yet.
package c4_init_direct3d

import "core:os"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import common "../common"

// C++: DirectX::Colors::LightSteelBlue.
LIGHT_STEEL_BLUE :: [4]f32{0.690196097, 0.768627524, 0.870588303, 1.0}

Init_Direct3D_App :: struct {
	using base: common.D3D_App, // Odin's subtype polymorphism: base as first field
	// (demo-specific fields — mLastMousePos etc. — arrive with the ImGui step)
}

main :: proc() {
	app: Init_Direct3D_App
	app.main_wnd_caption = "d3d App"
	app.update = update
	app.draw = draw

	// C++: theApp.Initialize(); theApp.Run();  (errors exit via report_error/hr_panic)
	common.d3d_app_init(&app.base)
	code := common.d3d_app_run(&app.base)
	common.d3d_app_shutdown(&app.base)
	os.exit(code)
}

// C++: InitDirect3DApp::Update — empty in this demo.
update :: proc(base: ^common.D3D_App) {
}

// C++: InitDirect3DApp::Draw.
draw :: proc(base: ^common.D3D_App) {
	// (Cast available for demo fields later: app := (^Init_Direct3D_App)(base))

	// Reuse the memory associated with command recording. We can only reset when the
	// associated command lists have finished execution on the GPU (this demo flushes per
	// frame below, so that's guaranteed here).
	common.hr_panic(base.direct_cmd_list_alloc->Reset(), "CommandAllocator Reset")

	// A command list can be reset after it has been added to the command queue via
	// ExecuteCommandList. Reusing the command list reuses memory.
	common.hr_panic(
		base.command_list->Reset(base.direct_cmd_list_alloc, nil),
		"CommandList Reset",
	)

	// (C++ sets the CbvSrvUav descriptor heap here for ImGui — next step.)

	base.command_list->RSSetViewports(1, &base.screen_viewport)
	base.command_list->RSSetScissorRects(1, &base.scissor_rect)

	// Indicate a state transition on the resource usage.
	// (Omitting this barrier is a great debug-layer smoke test: two ERRORs per frame on
	// stderr — ids 538 INVALID_RESOURCE_STATE and 527 barrier-mismatch. Verified 2026-07.)
	to_render_target := common.transition_barrier(
		common.current_back_buffer(base),
		{}, // D3D12_RESOURCE_STATE_PRESENT (== COMMON == 0)
		{.RENDER_TARGET},
	)
	base.command_list->ResourceBarrier(1, &to_render_target)

	// Clear the back buffer and depth buffer.
	clear_color := LIGHT_STEEL_BLUE
	rtv := common.current_back_buffer_view(base)
	dsv := common.depth_stencil_view(base)
	base.command_list->ClearRenderTargetView(rtv, &clear_color, 0, nil)
	base.command_list->ClearDepthStencilView(dsv, {.DEPTH, .STENCIL}, 1.0, 0, 0, nil)

	// Specify the buffers we are going to render to.
	base.command_list->OMSetRenderTargets(1, &rtv, true, &dsv)

	// (C++ renders the ImGui draw data here — next step.)

	// Indicate a state transition on the resource usage.
	to_present := common.transition_barrier(
		common.current_back_buffer(base),
		{.RENDER_TARGET},
		{}, // D3D12_RESOURCE_STATE_PRESENT
	)
	base.command_list->ResourceBarrier(1, &to_present)

	// Done recording commands.
	common.hr_panic(base.command_list->Close(), "CommandList Close")

	// Add the command list to the queue for execution.
	cmd_lists := [?]^d3d12.ICommandList{(^d3d12.ICommandList)(base.command_list)}
	base.command_queue->ExecuteCommandLists(len(cmd_lists), &cmd_lists[0])

	// Swap the back and front buffers.
	present_params := dxgi.PRESENT_PARAMETERS{}
	common.hr_panic(base.swap_chain->Present1(0, {}, &present_params), "Present1")
	base.curr_back_buffer = (base.curr_back_buffer + 1) % common.SWAP_CHAIN_BUFFER_COUNT

	// Wait until frame commands are complete. This waiting is inefficient and is done for
	// simplicity. Later (ch 7, FrameResources) we organize the rendering code so we do not
	// have to wait per frame.
	common.flush_command_queue(base)
}
