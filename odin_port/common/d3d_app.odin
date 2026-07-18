// Port of `Common/d3dApp.h/.cpp` (Frank Luna) — the framework every D3D demo shares.
//
// Shape of the port (no inheritance in Odin):
//
//  - D3D_App (struct) — all the base-class state, plus proc-pointer "virtuals"
//    (update/draw required; the mouse hooks optional). Demos embed it as their first field
//    via `using base: common.D3D_App` and cast the ^D3D_App they receive back to their own
//    type (Odin's subtype-polymorphism idiom, replacing the C++ virtual base class).
//  - d3d_app_init / d3d_app_run / d3d_app_shutdown — Initialize(), Run(), and ~D3DApp().
//    The C++ `GetApp()` singleton becomes a pointer in the window's GWLP_USERDATA slot
//    (a thin pointer here — no fat-pointer indirection like the Rust port needed).
//
// COM lifetime discipline (the part Rust's smart pointers did for free) is explicit here,
// exactly as the porting guide describes: every out-param interface is a reference we own
// and Release — locals via defer, long-lived fields in d3d_app_shutdown (queue flushed
// first, children before the device, device last).
//
// Deviations from the C++ (deliberate, same as the Rust port; see the guide):
//  - ImGui init/shutdown/new-frame: not yet ported (the ch 4 part-2 step).
//  - GraphicsMemory/ResourceUploadBatch (DirectXTK12): first used in ch 6–7; deferred.
//  - SamplerHeap, CbvSrvUavHeap: first bound by demos with shaders; deferred.
//  - Debug output goes to stderr — including the debug layer itself, via
//    ID3D12InfoQueue1::RegisterMessageCallback (pre-bound in vendor:directx/d3d12; the
//    guide's "validation to stderr" side quest costs a dozen lines here).
//  - The Agility SDK exports are omitted: Windows 11's inbox runtime already provides
//    SM 6.6 (verified against the C++ demos, which resolve to the system D3D12Core.dll).
package common

import "core:fmt"
import win "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import im "../libs/imgui"
import im_dx12 "../libs/imgui/backends/dx12"
import im_win32 "../libs/imgui/backends/win32"

SWAP_CHAIN_BUFFER_COUNT :: 2

// C++: gNumFrameResources (per-demo, = 3). Used by the ImGui DX12 backend now; the
// FrameResource ring itself arrives in ch 7.
NUM_FRAME_RESOURCES :: 3

D3D_App :: struct {
	hwnd:     win.HWND,
	instance: win.HINSTANCE,

	app_paused: bool, // is the application paused?
	minimized:  bool, // is the application minimized?
	maximized:  bool, // is the application maximized?
	resizing:   bool, // are the resize bars being dragged?

	timer: Game_Timer,

	dxgi_factory:    ^dxgi.IFactory6,
	swap_chain:      ^dxgi.ISwapChain4,
	default_adapter: ^dxgi.IAdapter4,
	device:          ^d3d12.IDevice5,

	fence:         ^d3d12.IFence,
	current_fence: u64,

	command_queue:         ^d3d12.ICommandQueue,
	direct_cmd_list_alloc: ^d3d12.ICommandAllocator,
	command_list:          ^d3d12.IGraphicsCommandList6,

	curr_back_buffer:     int,
	swap_chain_buffer:    [SWAP_CHAIN_BUFFER_COUNT]^d3d12.IResource,
	depth_stencil_buffer: ^d3d12.IResource,

	rtv_heap: Descriptor_Heap,
	dsv_heap: Descriptor_Heap,

	screen_viewport: d3d12.VIEWPORT,
	scissor_rect:    d3d12.RECT,

	// Derived "class" customizes these before d3d_app_init (like the C++ derived ctor).
	main_wnd_caption:     string,
	back_buffer_format:   dxgi.FORMAT,
	depth_stencil_format: dxgi.FORMAT,
	client_width:         i32,
	client_height:        i32,

	// The virtuals: update/draw are the book's pure virtuals; the rest are optional hooks.
	update:        proc(app: ^D3D_App),
	draw:          proc(app: ^D3D_App),
	on_mouse_down: proc(app: ^D3D_App, btn_state: win.WPARAM, x, y: i32),
	on_mouse_up:   proc(app: ^D3D_App, btn_state: win.WPARAM, x, y: i32),
	on_mouse_move: proc(app: ^D3D_App, btn_state: win.WPARAM, x, y: i32),

	// CalculateFrameStats' function-local statics in the C++.
	frame_cnt:    int,
	time_elapsed: f32,
}

aspect_ratio :: proc(app: ^D3D_App) -> f32 {
	return f32(app.client_width) / f32(app.client_height)
}

// C++: D3DApp::Initialize() — window, then Direct3D. Call d3d_app_run afterwards (which
// performs the initial OnResize, like the tail of the C++ Initialize).
d3d_app_init :: proc(app: ^D3D_App) {
	// Defaults from the C++ member initializers, for anything the demo didn't set.
	if app.main_wnd_caption == "" do app.main_wnd_caption = "d3d App"
	if app.back_buffer_format == .UNKNOWN do app.back_buffer_format = .R8G8B8A8_UNORM
	if app.depth_stencil_format == .UNKNOWN do app.depth_stencil_format = .D24_UNORM_S8_UINT
	if app.client_width == 0 do app.client_width = 1280
	if app.client_height == 0 do app.client_height = 720

	game_timer_init(&app.timer)
	app.instance = win.HINSTANCE(win.GetModuleHandleW(nil))

	init_main_window(app)
	init_direct3d(app)
}

// C++: D3DApp::InitMainWindow().
@(private)
init_main_window :: proc(app: ^D3D_App) {
	wc := win.WNDCLASSW {
		style         = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc   = wnd_proc,
		hInstance     = app.instance,
		hIcon         = win.LoadIconW(nil, win.LPCWSTR(win._IDI_APPLICATION)),
		hCursor       = win.LoadCursorW(nil, win.LPCWSTR(win._IDC_ARROW)),
		hbrBackground = win.HBRUSH(win.GetStockObject(win.NULL_BRUSH)),
		lpszMenuName  = nil,
		lpszClassName = win.L("MainWnd"),
	}
	if win.RegisterClassW(&wc) == 0 {
		report_error("RegisterClass Failed.") // C++: MessageBox(0, L"RegisterClass Failed.", 0, 0);
		win.ExitProcess(1)
	}

	// Compute window rectangle dimensions based on requested client area dimensions.
	r := win.RECT{0, 0, app.client_width, app.client_height}
	win.AdjustWindowRect(&r, win.WS_OVERLAPPEDWINDOW, false)
	width := r.right - r.left
	height := r.bottom - r.top

	app.hwnd = win.CreateWindowExW(
		0,
		win.L("MainWnd"),
		win.utf8_to_wstring(app.main_wnd_caption),
		win.WS_OVERLAPPEDWINDOW,
		win.CW_USEDEFAULT,
		win.CW_USEDEFAULT,
		width,
		height,
		nil,
		nil,
		app.instance,
		nil,
	)
	if app.hwnd == nil {
		report_error("CreateWindow Failed.") // C++: MessageBox(0, L"CreateWindow Failed.", 0, 0);
		win.ExitProcess(1)
	}

	// The C++ GetApp() singleton, replaced: stash ^D3D_App in the window's user-data slot
	// so wnd_proc can find us. (Messages sent during CreateWindowExW itself — WM_CREATE,
	// the initial WM_SIZE — see a null slot and fall through to DefWindowProc, mirroring
	// the C++ comment about messages arriving before mhMainWnd is valid.)
	win.SetWindowLongPtrW(app.hwnd, win.GWLP_USERDATA, win.LONG_PTR(uintptr(app)))

	win.ShowWindow(app.hwnd, win.SW_SHOW)
	win.UpdateWindow(app.hwnd)
}

// C++: D3DApp::InitDirect3D() + CreateCommandObjects() + CreateSwapChain() +
// CreateRtvAndDsvDescriptorHeaps().
@(private)
init_direct3d :: proc(app: ^D3D_App) {
	factory_flags: dxgi.CREATE_FACTORY

	when ODIN_DEBUG {
		factory_flags = {.DEBUG}

		// Enable the D3D12 debug layer.
		// C++ gets ID3D12Debug then QIs to ID3D12Debug1; requesting IDebug1 directly is
		// the same net result with one fewer interface to Release.
		debug1: ^d3d12.IDebug1
		hr_panic(
			d3d12.GetDebugInterface(d3d12.IDebug1_UUID, ptr(&debug1)),
			"D3D12GetDebugInterface",
		)
		defer debug1->Release() // local ComPtr in the C++: released at scope end
		debug1->EnableDebugLayer()
		// debug1->SetEnableGPUBasedValidation(true) — like the book, off by default.

		// DRED (Device Removed Extended Data): auto-breadcrumbs + page-fault data attached
		// to device-removal errors. The guide recommends enabling it before the compute
		// chapters; the interfaces are pre-bound, so it costs four lines. Must be set
		// BEFORE the device is created.
		dred: ^d3d12.IDeviceRemovedExtendedDataSettings
		if d3d12.GetDebugInterface(
			   d3d12.IDeviceRemovedExtendedDataSettings_UUID,
			   ptr(&dred),
		   ) >=
		   0 {
			dred->SetAutoBreadcrumbsEnablement(.FORCED_ON)
			dred->SetPageFaultEnablement(.FORCED_ON)
			dred->Release()
		}
	}

	hr_panic(
		dxgi.CreateDXGIFactory2(factory_flags, dxgi.IFactory6_UUID, ptr(&app.dxgi_factory)),
		"CreateDXGIFactory2",
	)

	// Find an adapter that supports D3D_FEATURE_LEVEL_12_2. This is mainly for laptops so
	// it picks the discrete GPU over the integrated GPU.
	found_adapter: ^dxgi.IAdapter
	for i: u32 = 0; ; i += 1 {
		adapter: ^dxgi.IAdapter
		if app.dxgi_factory->EnumAdapters(i, &adapter) == dxgi.ERROR_NOT_FOUND {
			break
		}
		// Try to create hardware device. (C++ creates ID3D12Device then QIs to
		// ID3D12Device5; requesting IDevice5 directly is equivalent.)
		if d3d12.CreateDevice(
			   (^d3d12.IUnknown)(adapter),
			   ._12_2,
			   d3d12.IDevice5_UUID,
			   ptr(&app.device),
		   ) >=
		   0 {
			found_adapter = adapter
			break
		}
		// Guide trap #4: each enumerated adapter is a reference; release the ones we
		// don't keep.
		adapter->Release()
	}
	if found_adapter == nil {
		report_error("Could not find D3D_FEATURE_LEVEL_12_2 GPU")
		win.ExitProcess(1)
	}

	// Get default adapter, so we can IDXGIAdapter3::QueryVideoMemoryInfo (used by demos).
	// C++: foundAdapter.As(&mDefaultAdapter) — QueryInterface AddRefs a NEW reference,
	// then the old one is released (guide trap #3, done by ComPtr scope in the C++).
	hr_panic(
		found_adapter->QueryInterface(dxgi.IAdapter4_UUID, ptr(&app.default_adapter)),
		"IDXGIAdapter::QueryInterface(IDXGIAdapter4)",
	)
	found_adapter->Release()

	hr_panic(
		app.device->CreateFence(0, {}, d3d12.IFence_UUID, ptr(&app.fence)),
		"CreateFence",
	)

	when ODIN_DEBUG {
		log_adapters(app)
		register_debug_callback(app)
	}

	// ---- CreateCommandObjects ----
	queue_desc := d3d12.COMMAND_QUEUE_DESC {
		Type = .DIRECT,
	}
	hr_panic(
		app.device->CreateCommandQueue(
			&queue_desc,
			d3d12.ICommandQueue_UUID,
			ptr(&app.command_queue),
		),
		"CreateCommandQueue",
	)
	hr_panic(
		app.device->CreateCommandAllocator(
			.DIRECT,
			d3d12.ICommandAllocator_UUID,
			ptr(&app.direct_cmd_list_alloc),
		),
		"CreateCommandAllocator",
	)
	// C++ creates ID3D12GraphicsCommandList then QIs to ...List6; direct request again.
	hr_panic(
		app.device->CreateCommandList(
			0,
			.DIRECT,
			app.direct_cmd_list_alloc, // Associated command allocator
			nil, //                       Initial PipelineStateObject
			d3d12.IGraphicsCommandList6_UUID,
			ptr(&app.command_list),
		),
		"CreateCommandList",
	)
	// Start off in a closed state. The first time we refer to the command list we Reset
	// it, and it needs to be closed before calling Reset.
	app.command_list->Close()

	// ---- CreateSwapChain ----
	sd := dxgi.SWAP_CHAIN_DESC1 {
		Width = u32(app.client_width),
		Height = u32(app.client_height),
		Format = app.back_buffer_format,
		Stereo = false,
		SampleDesc = {Count = 1, Quality = 0},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = SWAP_CHAIN_BUFFER_COUNT,
		Scaling = .NONE,
		SwapEffect = .FLIP_DISCARD,
		AlphaMode = .UNSPECIFIED,
		Flags = {.ALLOW_MODE_SWITCH},
	}
	// Note: swap chain uses queue to perform flush.
	swap_chain1: ^dxgi.ISwapChain1
	hr_panic(
		app.dxgi_factory->CreateSwapChainForHwnd(
			(^dxgi.IUnknown)(app.command_queue),
			app.hwnd,
			&sd,
			nil,
			nil,
			&swap_chain1,
		),
		"CreateSwapChainForHwnd",
	)
	// C++: swapChain1.As(&mSwapChain) — QI to the newer interface, release the old one
	// (guide trap #3 again, explicit here).
	hr_panic(
		swap_chain1->QueryInterface(dxgi.ISwapChain4_UUID, ptr(&app.swap_chain)),
		"IDXGISwapChain1::QueryInterface(IDXGISwapChain4)",
	)
	swap_chain1->Release()

	// ---- CreateRtvAndDsvDescriptorHeaps ----
	descriptor_heap_init(&app.rtv_heap, app.device, .RTV, SWAP_CHAIN_BUFFER_COUNT)
	descriptor_heap_init(&app.dsv_heap, app.device, .DSV, 1)

	// (Deferred vs the C++: SamplerHeap, GraphicsMemory, ResourceUploadBatch — see the
	// package docs. They arrive with the chapters that first use them.)
}

// C++: FlushCommandQueue() — half the book's correctness hangs off this.
flush_command_queue :: proc(app: ^D3D_App) {
	// Advance the fence value to mark commands up to this fence point.
	app.current_fence += 1

	// Because we are on the GPU timeline, the new fence point won't be set until the GPU
	// finishes processing all the commands prior to this Signal().
	hr_panic(app.command_queue->Signal(app.fence, app.current_fence), "Signal")

	// Wait until the GPU has completed commands up to this fence point.
	if app.fence->GetCompletedValue() < app.current_fence {
		event := win.CreateEventW(nil, false, false, nil)
		// Fire event when GPU hits current fence.
		hr_panic(
			app.fence->SetEventOnCompletion(app.current_fence, event),
			"SetEventOnCompletion",
		)
		// Wait until the GPU hits current fence event is fired.
		win.WaitForSingleObject(event, win.INFINITE)
		win.CloseHandle(event)
	}
}

// C++: D3DApp::OnResize() — THE ComPtr trap of the book lives here: every back-buffer
// reference must be released before ResizeBuffers, or it fails with E_INVALIDARG
// ("buffer still referenced").
on_resize :: proc(app: ^D3D_App) {
	assert(app.device != nil)
	assert(app.swap_chain != nil)
	assert(app.direct_cmd_list_alloc != nil)

	// Flush before changing any resources.
	flush_command_queue(app)

	hr_panic(app.command_list->Reset(app.direct_cmd_list_alloc, nil), "CommandList Reset")

	// Release the previous resources we will be recreating.
	for &buffer in app.swap_chain_buffer {
		if buffer != nil {
			buffer->Release() // C++: mSwapChainBuffer[i].Reset();
			buffer = nil
		}
	}
	if app.depth_stencil_buffer != nil {
		app.depth_stencil_buffer->Release()
		app.depth_stencil_buffer = nil
	}

	// Resize the swap chain.
	hr_panic(
		app.swap_chain->ResizeBuffers(
			SWAP_CHAIN_BUFFER_COUNT,
			u32(app.client_width),
			u32(app.client_height),
			app.back_buffer_format,
			{.ALLOW_MODE_SWITCH},
		),
		"ResizeBuffers",
	)

	app.curr_back_buffer = 0

	for i in 0 ..< SWAP_CHAIN_BUFFER_COUNT {
		// Each GetBuffer AddRefs — we own the new back buffers again.
		hr_panic(
			app.swap_chain->GetBuffer(
				u32(i),
				d3d12.IResource_UUID,
				ptr(&app.swap_chain_buffer[i]),
			),
			"GetBuffer",
		)
		rtv := cpu_handle(&app.rtv_heap, u32(i))
		app.device->CreateRenderTargetView(app.swap_chain_buffer[i], nil, rtv)
	}

	// Create the depth/stencil buffer and view.
	depth_stencil_desc := d3d12.RESOURCE_DESC {
		Dimension        = .TEXTURE2D,
		Alignment        = 0,
		Width            = u64(app.client_width),
		Height           = u32(app.client_height),
		DepthOrArraySize = 1,
		MipLevels        = 1,
		Format           = app.depth_stencil_format,
		SampleDesc       = {Count = 1, Quality = 0},
		Layout           = .UNKNOWN,
		Flags            = {.ALLOW_DEPTH_STENCIL},
	}
	heap_properties := d3d12.HEAP_PROPERTIES {
		Type = .DEFAULT,
	}
	opt_clear := d3d12.CLEAR_VALUE {
		Format = app.depth_stencil_format,
	}
	opt_clear.DepthStencil = {Depth = 1.0, Stencil = 0}
	hr_panic(
		app.device->CreateCommittedResource(
			&heap_properties,
			{},
			&depth_stencil_desc,
			{}, // D3D12_RESOURCE_STATE_COMMON
			&opt_clear,
			d3d12.IResource_UUID,
			ptr(&app.depth_stencil_buffer),
		),
		"CreateCommittedResource(depth)",
	)

	// Create descriptor to mip level 0 of entire resource using the resource's format.
	app.device->CreateDepthStencilView(app.depth_stencil_buffer, nil, depth_stencil_view(app))

	// Transition the resource from its initial state to be used as a depth buffer.
	depth_barrier := transition_barrier(app.depth_stencil_buffer, {}, {.DEPTH_WRITE})
	app.command_list->ResourceBarrier(1, &depth_barrier)

	// Execute the resize commands.
	hr_panic(app.command_list->Close(), "CommandList Close")
	cmd_lists := [?]^d3d12.ICommandList{(^d3d12.ICommandList)(app.command_list)}
	app.command_queue->ExecuteCommandLists(len(cmd_lists), &cmd_lists[0])

	// Wait until resize is complete.
	flush_command_queue(app)

	// Update the viewport transform to cover the client area.
	app.screen_viewport = {
		TopLeftX = 0,
		TopLeftY = 0,
		Width    = f32(app.client_width),
		Height   = f32(app.client_height),
		MinDepth = 0,
		MaxDepth = 1,
	}
	app.scissor_rect = {0, 0, app.client_width, app.client_height}
}

// C++: CurrentBackBuffer().
current_back_buffer :: proc(app: ^D3D_App) -> ^d3d12.IResource {
	return app.swap_chain_buffer[app.curr_back_buffer]
}

// C++: CurrentBackBufferView().
current_back_buffer_view :: proc(app: ^D3D_App) -> d3d12.CPU_DESCRIPTOR_HANDLE {
	return cpu_handle(&app.rtv_heap, u32(app.curr_back_buffer))
}

// C++: DepthStencilView().
depth_stencil_view :: proc(app: ^D3D_App) -> d3d12.CPU_DESCRIPTOR_HANDLE {
	return cpu_handle(&app.dsv_heap, 0)
}

// C++: D3DApp::Run() — the PeekMessage game loop (the initial OnResize is the tail of the
// C++ Initialize; done here so init/run split cleanly).
d3d_app_run :: proc(app: ^D3D_App) -> int {
	on_resize(app)

	msg: win.MSG
	game_timer_reset(&app.timer)

	for msg.message != win.WM_QUIT {
		// If there are Window messages then process them.
		if win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		} else {
			// Otherwise, do animation/game stuff.
			game_timer_tick(&app.timer)

			if !app.app_paused {
				calculate_frame_stats(app)
				app.update(app)
				app.draw(app)
			} else {
				win.Sleep(100)
			}
		}
	}

	return int(msg.wParam)
}

// C++: D3DApp::InitImgui(CbvSrvUavHeap&) — call after the demo builds its CbvSrvUav heap.
d3d_app_init_imgui :: proc(app: ^D3D_App, heap: ^Cbv_Srv_Uav_Heap) {
	im.CHECKVERSION()
	im.CreateContext()

	// Setup Dear ImGui style
	im.StyleColorsDark()
	//im.StyleColorsClassic()

	// Setup Platform/Renderer backends. The book's ImGui (1.85 era) took a single SRV
	// descriptor; 1.92 asks the app to own SRV allocation via callbacks — which map
	// exactly onto CbvSrvUavHeap's next_free_index/release_index.
	im_win32.Init(app.hwnd)
	init_info := im_dx12.InitInfo {
		Device            = (^d3d12.IDevice)(app.device),
		CommandQueue      = app.command_queue,
		NumFramesInFlight = NUM_FRAME_RESOURCES,
		RTVFormat         = app.back_buffer_format,
		DSVFormat         = app.depth_stencil_format,
		UserData          = heap,
		SrvDescriptorHeap = heap.heap,
		SrvDescriptorAllocFn = proc "c" (
			info: ^im_dx12.InitInfo,
			out_cpu: ^d3d12.CPU_DESCRIPTOR_HANDLE,
			out_gpu: ^d3d12.GPU_DESCRIPTOR_HANDLE,
		) {
			context = default_context() // "c" callback: no Odin context
			heap := (^Cbv_Srv_Uav_Heap)(info.UserData)
			index := next_free_index(heap)
			out_cpu^ = cpu_handle(heap, index)
			out_gpu^ = gpu_handle(heap, index)
		},
		SrvDescriptorFreeFn = proc "c" (
			info: ^im_dx12.InitInfo,
			cpu: d3d12.CPU_DESCRIPTOR_HANDLE,
			gpu: d3d12.GPU_DESCRIPTOR_HANDLE,
		) {
			context = default_context()
			heap := (^Cbv_Srv_Uav_Heap)(info.UserData)
			// Recover the bindless index from the handle offset.
			start: d3d12.GPU_DESCRIPTOR_HANDLE
			heap.heap->GetGPUDescriptorHandleForHeapStart(&start)
			release_index(heap, u32((gpu.ptr - start.ptr) / u64(heap.descriptor_size)))
		},
	}
	im_dx12.Init(&init_info)
}

// C++: D3DApp::UpdateImgui — begin a new ImGui frame. Demos call this first in their own
// update_imgui, add widgets, then im.Render() (mirroring the C++ virtual + base call).
d3d_app_update_imgui_base :: proc() {
	im_dx12.NewFrame()
	im_win32.NewFrame()
	im.NewFrame()
}

// C++: D3DApp::ShutdownImgui() — call BEFORE cbv_srv_uav_heap_destroy and
// d3d_app_shutdown: the DX12 backend frees its SRV descriptors through the heap's
// callbacks, and its device objects must go before the device.
d3d_app_shutdown_imgui :: proc(app: ^D3D_App) {
	if im.GetCurrentContext() != nil {
		flush_command_queue(app) // GPU may still reference the font texture
		im_dx12.Shutdown()
		im_win32.Shutdown()
		im.DestroyContext()
	}
}

// C++: ~D3DApp() + the deinit order rules from the guide: flush queue first, children
// before parents, device last. (This is the discipline Rust's Drop impls performed
// implicitly — in Odin it reads like the C++ without ComPtr.)
d3d_app_shutdown :: proc(app: ^D3D_App) {
	if app.device != nil {
		flush_command_queue(app)
	}

	for &buffer in app.swap_chain_buffer {
		if buffer != nil {buffer->Release();buffer = nil}
	}
	if app.depth_stencil_buffer != nil {app.depth_stencil_buffer->Release()}
	descriptor_heap_destroy(&app.rtv_heap)
	descriptor_heap_destroy(&app.dsv_heap)
	if app.command_list != nil {app.command_list->Release()}
	if app.direct_cmd_list_alloc != nil {app.direct_cmd_list_alloc->Release()}
	if app.command_queue != nil {app.command_queue->Release()}
	// (Omitting any one of these Releases is the leak-detector smoke test: the report at
	// the end prints e.g. "Live ID3D12Fence at …, Refcount: 1". Verified 2026-07.)
	if app.fence != nil {app.fence->Release()}
	if app.swap_chain != nil {app.swap_chain->Release()}
	if app.default_adapter != nil {app.default_adapter->Release()}
	if app.device != nil {app.device->Release()}
	if app.dxgi_factory != nil {app.dxgi_factory->Release()}

	// Everything above should have brought every refcount to zero — prove it.
	when ODIN_DEBUG {
		report_live_objects()
	}
}

// The guide's leak-report step: after shutdown, ask DXGI to report any COM object still
// alive, and pull the report onto stderr (its native channels are the DXGI info queue and
// the debugger output we can't see). A clean run prints nothing; a missing Release prints
// the leaked object with its refcount.
//
// vendor:directx/dxgi binds the dxgidebug *interfaces* (dxgidebug.odin) but not the entry
// point — DXGIGetDebugInterface1 lives in dxgidebug.dll, a development-only DLL — so load
// it at runtime and degrade gracefully when absent.
@(private)
report_live_objects :: proc() {
	// DXGIGetDebugInterface1 is exported by dxgi.dll (already loaded); it internally
	// requires dxgidebug.dll (the development-only DLL) and fails cleanly without it.
	// (Trap discovered here: the similarly-named DXGIGetDebugInterface — no "1" — is the
	// one that lives in dxgidebug.dll.)
	dxgi_module := win.GetModuleHandleW(win.L("dxgi.dll"))
	if dxgi_module == nil {
		return
	}
	get_debug_interface :=
	(proc "system" (flags: u32, riid: ^dxgi.IID, out: ^rawptr) -> dxgi.HRESULT)(win.GetProcAddress(dxgi_module, "DXGIGetDebugInterface1"))
	if get_debug_interface == nil {
		return
	}

	dxgi_debug: ^dxgi.IDebug
	if get_debug_interface(0, dxgi.IDebug_UUID, (^rawptr)(&dxgi_debug)) < 0 {
		return
	}
	defer dxgi_debug->Release()

	// Writes the report into the DXGI info queue; .ALL = SUMMARY|DETAIL|IGNORE_INTERNAL.
	dxgi_debug->ReportLiveObjects(dxgi.DEBUG_ALL, .ALL)

	// Pull the report out of the queue onto stderr (two-call GetMessage: size, then fill).
	info_queue: ^dxgi.IInfoQueue
	if get_debug_interface(0, dxgi.IInfoQueue_UUID, (^rawptr)(&info_queue)) < 0 {
		return
	}
	defer info_queue->Release()

	n := info_queue->GetNumStoredMessages(dxgi.DEBUG_ALL)
	for i in 0 ..< n {
		length: dxgi.SIZE_T
		info_queue->GetMessage(dxgi.DEBUG_ALL, i, nil, &length)
		buf := make([]byte, int(length), context.temp_allocator)
		msg := (^dxgi.INFO_QUEUE_MESSAGE)(raw_data(buf))
		if info_queue->GetMessage(dxgi.DEBUG_ALL, i, msg, &length) >= 0 {
			fmt.eprintfln("[dxgi-live %v] %s", msg.Severity, cstring(msg.pDescription))
		}
	}
	info_queue->ClearStoredMessages(dxgi.DEBUG_ALL)
}

// C++: CalculateFrameStats() — average FPS/mspf appended to the window caption.
@(private)
calculate_frame_stats :: proc(app: ^D3D_App) {
	app.frame_cnt += 1

	// Compute averages over one second period.
	if game_timer_total_time(&app.timer) - app.time_elapsed >= 1.0 {
		fps := f32(app.frame_cnt) // fps = frame_cnt / 1
		mspf := 1000.0 / fps

		// %.6f matches C++ std::to_wstring(float)'s formatting.
		window_text := fmt.tprintf("%s    fps: %.6f   mspf: %.6f", app.main_wnd_caption, fps, mspf)
		win.SetWindowTextW(app.hwnd, win.utf8_to_wstring(window_text))

		// Reset for next average.
		app.frame_cnt = 0
		app.time_elapsed += 1.0
	}
}

@(private)
get_x_lparam :: proc "contextless" (lparam: win.LPARAM) -> i32 {
	return i32(i16(u16(uint(lparam) & 0xffff))) // WindowsX.h GET_X_LPARAM
}
@(private)
get_y_lparam :: proc "contextless" (lparam: win.LPARAM) -> i32 {
	return i32(i16(u16((uint(lparam) >> 16) & 0xffff))) // WindowsX.h GET_Y_LPARAM
}

// The registered window procedure: recover ^D3D_App from GWLP_USERDATA and run the book's
// MsgProc, verbatim. `proc "system"` has no Odin context; restore it (fmt/asserts inside).
@(private)
wnd_proc :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
) -> win.LRESULT {
	context = default_context()

	// Hook Imgui into the message pump (C++: MainWndProc). Before ImGui init this is a
	// harmless no-op returning 0.
	if im_win32.WndProcHandler(hwnd, msg, wparam, lparam) != 0 {
		return 1
	}

	app := (^D3D_App)(uintptr(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA)))
	if app == nil {
		// Messages before init_main_window stored the pointer (e.g. WM_CREATE).
		return win.DefWindowProcW(hwnd, msg, wparam, lparam)
	}

	switch msg {
	// WM_ACTIVATE is sent when the window is activated or deactivated. We pause the game
	// when the window is deactivated and unpause it when it becomes active.
	case win.WM_ACTIVATE:
		if win.LOWORD(win.DWORD(wparam)) == win.WA_INACTIVE {
			app.app_paused = true
			game_timer_stop(&app.timer)
		} else {
			app.app_paused = false
			game_timer_start(&app.timer)
		}
		return 0

	// WM_SIZE is sent when the user resizes the window.
	case win.WM_SIZE:
		// Save the new client area dimensions.
		app.client_width = get_x_lparam(lparam)
		app.client_height = get_y_lparam(lparam)
		if app.device != nil {
			switch wparam {
			case win.SIZE_MINIMIZED:
				app.app_paused = true
				app.minimized = true
				app.maximized = false
			case win.SIZE_MAXIMIZED:
				app.app_paused = false
				app.minimized = false
				app.maximized = true
				on_resize(app)
			case win.SIZE_RESTORED:
				if app.minimized {
					// Restoring from minimized state?
					app.app_paused = false
					app.minimized = false
					on_resize(app)
				} else if app.maximized {
					// Restoring from maximized state?
					app.app_paused = false
					app.maximized = false
					on_resize(app)
				} else if app.resizing {
					// While the user drags the resize bars a stream of WM_SIZE messages
					// arrives; resizing per message would be pointless and slow. Wait for
					// WM_EXITSIZEMOVE instead.
				} else {
					// API call such as SetWindowPos or SetFullscreenState.
					on_resize(app)
				}
			}
		}
		return 0

	// WM_ENTERSIZEMOVE is sent when the user grabs the resize bars.
	case win.WM_ENTERSIZEMOVE:
		app.app_paused = true
		app.resizing = true
		game_timer_stop(&app.timer)
		return 0

	// WM_EXITSIZEMOVE is sent when the user releases the resize bars.
	// Here we reset everything based on the new window dimensions.
	case win.WM_EXITSIZEMOVE:
		app.app_paused = false
		app.resizing = false
		game_timer_start(&app.timer)
		on_resize(app)
		return 0

	// WM_DESTROY is sent when the window is being destroyed.
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		return 0

	// The WM_MENUCHAR message is sent when a menu is active and the user presses a key
	// that does not correspond to any mnemonic or accelerator key.
	case win.WM_MENUCHAR:
		// Don't beep when we alt-enter. MAKELRESULT(0, MNC_CLOSE).
		return 0x0001_0000

	// Catch this message so as to prevent the window from becoming too small.
	case win.WM_GETMINMAXINFO:
		info := (^win.MINMAXINFO)(uintptr(lparam))
		info.ptMinTrackSize.x = 200
		info.ptMinTrackSize.y = 200
		return 0

	case win.WM_LBUTTONDOWN, win.WM_MBUTTONDOWN, win.WM_RBUTTONDOWN:
		if app.on_mouse_down != nil {
			app->on_mouse_down(wparam, get_x_lparam(lparam), get_y_lparam(lparam))
		}
		return 0
	case win.WM_LBUTTONUP, win.WM_MBUTTONUP, win.WM_RBUTTONUP:
		if app.on_mouse_up != nil {
			app->on_mouse_up(wparam, get_x_lparam(lparam), get_y_lparam(lparam))
		}
		return 0
	case win.WM_MOUSEMOVE:
		if app.on_mouse_move != nil {
			app->on_mouse_move(wparam, get_x_lparam(lparam), get_y_lparam(lparam))
		}
		return 0
	case win.WM_KEYUP:
		if wparam == win.VK_ESCAPE {
			win.PostQuitMessage(0)
		}
		return 0
	}

	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// The guide's "validation to stderr" side quest — nearly free in Odin because IInfoQueue1
// and RegisterMessageCallback are pre-bound in vendor:directx/d3d12.
@(private)
register_debug_callback :: proc(app: ^D3D_App) {
	debug_callback :: proc "c" ( // vendor's PFN_MESSAGE_CALLBACK is cdecl
		category: d3d12.MESSAGE_CATEGORY,
		severity: d3d12.MESSAGE_SEVERITY,
		id: d3d12.MESSAGE_ID,
		description: cstring,
		ctx: rawptr,
	) {
		context = default_context() // "system" proc: no context until we set one
		fmt.eprintfln("[d3d12 %v] (id %v) %s", severity, i32(id), description)
	}

	// The QI fails when the debug layer is off (release builds); that's fine.
	info_queue: ^d3d12.IInfoQueue1
	if app.device->QueryInterface(d3d12.IInfoQueue1_UUID, ptr(&info_queue)) >= 0 {
		cookie: u32
		info_queue->RegisterMessageCallback(debug_callback, {}, nil, &cookie)
		info_queue->Release()
	}
}

// C++: LogAdapters()/LogAdapterOutputs() — to stderr instead of OutputDebugString.
@(private)
log_adapters :: proc(app: ^D3D_App) {
	for i: u32 = 0; ; i += 1 {
		adapter: ^dxgi.IAdapter
		if app.dxgi_factory->EnumAdapters(i, &adapter) == dxgi.ERROR_NOT_FOUND {
			break
		}
		defer adapter->Release()

		desc: dxgi.ADAPTER_DESC
		if adapter->GetDesc(&desc) >= 0 {
			name, _ := win.utf16_to_utf8(desc.Description[:], context.temp_allocator)
			fmt.eprintfln("***Adapter: %s", name)
		}
		for j: u32 = 0; ; j += 1 {
			output: ^dxgi.IOutput
			if adapter->EnumOutputs(j, &output) == dxgi.ERROR_NOT_FOUND {
				break
			}
			defer output->Release()

			odesc: dxgi.OUTPUT_DESC
			if output->GetDesc(&odesc) >= 0 {
				name, _ := win.utf16_to_utf8(odesc.DeviceName[:], context.temp_allocator)
				fmt.eprintfln("***Output: %s", name)
			}
		}
	}
}
