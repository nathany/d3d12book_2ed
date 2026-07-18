// Port of `Demos/C4_Init Direct3D` — chapter 4's initialization demo: clear the screen to
// LightSteelBlue every frame; FPS/mspf in the title bar; the ImGui "Options" overlay with
// live video-memory stats; resize must survive repeated abuse (the chapter's real test —
// it exercises the OnResize/ResizeBuffers back-buffer trap).
//
// Build & run: odin run odin_port/C4_Init_Direct3D -debug     (debug layer + stderr log)
//
// ImGui comes from odin_port/libs/imgui (vendored Capati/odin-imgui, Dear ImGui
// 1.92.8-docking, win32+dx12 backends — see odin_port/README.md for the rebuild/copy
// steps; the .lib is gitignored). One C++ panel section is omitted:
// GraphicsMemoryStatistics reads DirectXTK12's GraphicsMemory, which this port replaces
// with its own upload arena in ch 6–7 — its stats join the panel then.
package c4_init_direct3d

import "core:os"
import win "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import common "../common"
import im "../libs/imgui"
import im_dx12 "../libs/imgui/backends/dx12"

// C++: DirectX::Colors::LightSteelBlue.
LIGHT_STEEL_BLUE :: [4]f32{0.690196097, 0.768627524, 0.870588303, 1.0}

// C++: constexpr UINT CBV_SRV_UAV_HEAP_CAPACITY = 16384;
CBV_SRV_UAV_HEAP_CAPACITY :: 16384

Init_Direct3D_App :: struct {
	using base:          common.D3D_App, // Odin's subtype polymorphism: base as first field
	cbv_srv_uav_heap:    common.Cbv_Srv_Uav_Heap,
	last_mouse_pos:      [2]i32, // C++: POINT mLastMousePos
	video_mem_poll_time: f32,
	video_mem_info:      dxgi.QUERY_VIDEO_MEMORY_INFO,
}

main :: proc() {
	app: Init_Direct3D_App
	app.main_wnd_caption = "d3d App"
	app.update = update
	app.draw = draw
	app.on_mouse_down = on_mouse_down
	app.on_mouse_up = on_mouse_up
	app.on_mouse_move = on_mouse_move

	// C++: theApp.Initialize() — D3DApp::Initialize + BuildCbvSrvUavDescriptorHeap.
	common.d3d_app_init(&app.base)
	common.cbv_srv_uav_heap_init(&app.cbv_srv_uav_heap, app.device, CBV_SRV_UAV_HEAP_CAPACITY)
	common.d3d_app_init_imgui(&app.base, &app.cbv_srv_uav_heap)

	// C++: theApp.Run();
	code := common.d3d_app_run(&app.base)

	// Teardown, C++ destructor order: ImGui first (frees its SRV via the heap callbacks
	// and its device objects), then the heap, then the base — whose final leak report
	// should stay silent.
	common.d3d_app_shutdown_imgui(&app.base)
	common.cbv_srv_uav_heap_destroy(&app.cbv_srv_uav_heap)
	common.d3d_app_shutdown(&app.base)
	os.exit(code)
}

// C++: InitDirect3DApp::Update — empty in this demo.
update :: proc(base: ^common.D3D_App) {
}

// C++: InitDirect3DApp::UpdateImgui — the "Options" panel.
update_imgui :: proc(app: ^Init_Direct3D_App) {
	common.d3d_app_update_imgui_base() // C++: D3DApp::UpdateImgui(gt) — the NewFrame trio

	//
	// Define a panel to render GUI elements.
	//
	im.Begin("Options")

	io := im.GetIO()
	im.Text(
		"Application average %.3f ms/frame (%.1f FPS)",
		f64(1000.0 / io.Framerate),
		f64(io.Framerate),
	)

	if im.CollapsingHeader("VideoMemoryInfo") {
		app.video_mem_poll_time += common.game_timer_delta_time(&app.timer)
		if app.video_mem_poll_time >= 1.0 { // poll every second
			app.default_adapter->QueryVideoMemoryInfo(
				0, // assume single GPU
				.LOCAL, // interested in local GPU memory, not shared
				&app.video_mem_info,
			)
			app.video_mem_poll_time -= 1.0
		}

		im.Text("Budget (bytes): %llu", app.video_mem_info.Budget)
		im.Text("CurrentUsage (bytes): %llu", app.video_mem_info.CurrentUsage)
		im.Text("AvailableForReservation (bytes): %llu", app.video_mem_info.AvailableForReservation)
		im.Text("CurrentReservation (bytes): %llu", app.video_mem_info.CurrentReservation)
	}
	// (C++ has a GraphicsMemoryStatistics section here — DirectXTK12; see file header.)

	im.End()

	im.Render()
}

// C++: InitDirect3DApp::Draw.
draw :: proc(base: ^common.D3D_App) {
	app := (^Init_Direct3D_App)(base)

	update_imgui(app) // C++: UpdateImgui(gt) at the top of Draw

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

	// C++: SetDescriptorHeaps — the shader-visible heap ImGui's font SRV lives in.
	descriptor_heaps := [?]^d3d12.IDescriptorHeap{app.cbv_srv_uav_heap.heap}
	base.command_list->SetDescriptorHeaps(len(descriptor_heaps), &descriptor_heaps[0])

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

	// Draw imgui UI.
	// C++: ImGui_ImplDX12_RenderDrawData(ImGui::GetDrawData(), mCommandList.Get());
	im_dx12.RenderDrawData(im.GetDrawData(), (^d3d12.IGraphicsCommandList)(base.command_list))

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

// C++: InitDirect3DApp::OnMouseDown — ImGui gets first claim on the mouse.
on_mouse_down :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Init_Direct3D_App)(base)
	io := im.GetIO()
	if !io.WantCaptureMouse {
		app.last_mouse_pos = {x, y}
		win.SetCapture(base.hwnd)
	}
}

// C++: InitDirect3DApp::OnMouseUp.
on_mouse_up :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	io := im.GetIO()
	if !io.WantCaptureMouse {
		win.ReleaseCapture()
	}
}

// C++: InitDirect3DApp::OnMouseMove.
on_mouse_move :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Init_Direct3D_App)(base)
	io := im.GetIO()
	if !io.WantCaptureMouse {
		app.last_mouse_pos = {x, y}
	}
}
