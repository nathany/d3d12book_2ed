// Port of `Demos/C7_Waves` (WavesApp.cpp/.h) — chapter 7's second demo: hills built from
// a height function over a MeshGen grid, and a 128x128 water surface whose vertices are
// simulated on the CPU each frame and streamed through a **per-frame dynamic vertex
// buffer** (an Upload_Buffer in each FrameResource — the same "can't touch it while the
// GPU reads it" rule as the constant buffers, solved the same way). Wave speed/damping/
// scale are live ImGui sliders.
//
// The C++'s unused BuildShapeGeometry leftover is omitted. The simulation itself is in
// waves.odin (serial — see its header).
//
// Build & run FROM THE REPO ROOT (shader path + DXC DLLs are resolved relative to it):
//   odin run odin_port/C7_Waves -debug
package c7_waves

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:slice"
import win "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxc "vendor:directx/dxc"
import dxgi "vendor:directx/dxgi"
import common "../common"
import "../d3d_math"
import im "../libs/imgui"
import im_dx12 "../libs/imgui/backends/dx12"

// C++: DirectX::Colors::LightSteelBlue.
LIGHT_STEEL_BLUE :: [4]f32{0.690196097, 0.768627524, 0.870588303, 1.0}

// C++: constexpr UINT CBV_SRV_UAV_HEAP_CAPACITY = 16384;
CBV_SRV_UAV_HEAP_CAPACITY :: 16384

// C++: enum ROOT_ARG. Perfomance TIP: Order from most frequent to least frequent.
Root_Arg :: enum u32 {
	OBJECT_CBV = 0,
	PASS_CBV,
}

// C++: enum class RenderLayer.
Render_Layer :: enum {
	Opaque,
	Debug,
	Sky,
}

// Lightweight structure stores parameters to draw a shape (same as C7_Shapes).
Render_Item :: struct {
	world:                   d3d_math.Mat4,
	tex_transform:           d3d_math.Mat4,
	object_cb:               Object_Constants,
	mem_handle_to_object_cb: common.Graphics_Resource,
	geo:                     ^common.Mesh_Geometry,
	primitive_type:          d3d12.PRIMITIVE_TOPOLOGY,
	index_count:             u32,
	start_index_location:    u32,
	base_vertex_location:    i32,
}

Waves_App :: struct {
	using base:                common.D3D_App,
	cbv_srv_uav_heap:          common.Cbv_Srv_Uav_Heap,

	frame_resources:           [common.NUM_FRAME_RESOURCES]Frame_Resource,
	curr_frame_resource:       ^Frame_Resource,
	curr_frame_resource_index: int,

	root_signature:            ^d3d12.IRootSignature,

	geometries:                map[string]^common.Mesh_Geometry,
	shaders:                   map[string]^dxc.IBlob,
	psos:                      map[string]^d3d12.IPipelineState,

	input_layout:              [2]d3d12.INPUT_ELEMENT_DESC,

	all_ritems:                [dynamic]^Render_Item,
	ritem_layer:               [Render_Layer][dynamic]^Render_Item,

	waves_ritem:               ^Render_Item,
	waves:                     Waves,
	t_base:                    f32, // C++: function-local static in UpdateWaves

	main_pass_cb:              Pass_Constants,

	view:                      d3d_math.Mat4,
	proj:                      d3d_math.Mat4,

	eye_pos:                   [3]f32,
	theta:                     f32,
	phi:                       f32,
	radius:                    f32,

	last_mouse_pos:            [2]i32, // C++: POINT mLastMousePos

	draw_wireframe:            bool,
	wave_scale:                f32,
	wave_speed:                f32,
	wave_damping:              f32,

	video_mem_poll_time:       f32,
	video_mem_info:            dxgi.QUERY_VIDEO_MEMORY_INFO,
}

main :: proc() {
	context = common.mem_track_init() // Odin-side leak detection (debug builds); see common/mem_track.odin

	app: Waves_App

	// C++ member initializers (WavesApp.h).
	app.view = d3d_math.MAT4_IDENTITY
	app.proj = d3d_math.MAT4_IDENTITY
	app.theta = 1.5 * math.PI
	app.phi = math.PI / 2 - 0.1
	app.radius = 50.0
	app.draw_wireframe = true
	app.wave_scale = 1.0
	app.wave_speed = 8.0
	app.wave_damping = 0.1

	app.update = update
	app.draw = draw
	app.on_resize = on_resize
	app.on_mouse_down = on_mouse_down
	app.on_mouse_up = on_mouse_up
	app.on_mouse_move = on_mouse_move

	// C++: WavesApp::Initialize().
	common.d3d_app_init(&app.base)

	waves_init(&app.waves, 128, 128, 1.0, 0.016, app.wave_speed, app.wave_damping)

	// We will upload on the direct queue for the book samples, but
	// copy queue would be better for real game.
	upload_batch: common.Resource_Upload_Batch
	common.upload_batch_begin(&upload_batch, app.device)

	land_geo := build_land_geometry(&app, &upload_batch)
	app.geometries[land_geo.name] = land_geo

	wave_geo := build_wave_geometry(&app, &upload_batch)
	app.geometries[wave_geo.name] = wave_geo

	// (C++ overlaps the upload with the rest of init via std::future; see C6_Box.)
	common.upload_batch_end_and_wait(&upload_batch, app.command_queue)

	// Other init work...
	build_root_signature(&app)
	build_cbv_srv_uav_descriptor_heap(&app)
	build_shaders_and_input_layout(&app)
	build_render_items(&app)
	build_frame_resources(&app)
	build_psos(&app)

	// C++: theApp.Run();
	code := common.d3d_app_run(&app.base)

	// Teardown, C++ destructor order: ImGui first, then the demo's own objects, then the
	// heap, then the base — whose final leak report should stay silent.
	common.d3d_app_shutdown_imgui(&app.base)
	for _, pso in app.psos {pso->Release()}
	delete(app.psos)
	for _, shader in app.shaders {shader->Release()}
	delete(app.shaders)
	if app.root_signature != nil {app.root_signature->Release()}
	for &fr in app.frame_resources {frame_resource_destroy(&fr)}
	for ritem in app.all_ritems {free(ritem)}
	delete(app.all_ritems)
	for &layer in app.ritem_layer {delete(layer)}
	// waterGeo's vertex buffer is a BORROW of the current frame resource's waves_vb
	// (already released above). The C++ ComPtr assignment AddRef'd it, so its destructor
	// Release is balanced there; here we must nil the borrow before destroy or we would
	// double-Release. (See update_waves.)
	app.geometries["waterGeo"].vertex_buffer_gpu = nil
	for _, geo in app.geometries {common.mesh_geometry_destroy(geo);free(geo)}
	delete(app.geometries)
	waves_destroy(&app.waves)
	common.cbv_srv_uav_heap_destroy(&app.cbv_srv_uav_heap)
	common.d3d_app_shutdown(&app.base)
	common.mem_track_report() // before os.exit — os.exit skips defers
	os.exit(code)
}

// C++: WavesApp::OnResize.
on_resize :: proc(base: ^common.D3D_App) {
	app := (^Waves_App)(base)

	common.on_resize(base) // C++: D3DApp::OnResize();

	// The window resized, so update the aspect ratio and recompute the projection matrix.
	app.proj = d3d_math.perspective_fov_lh(
		0.25 * math.PI,
		common.aspect_ratio(base),
		1.0,
		1000.0,
	)
}

// C++: WavesApp::Update.
update :: proc(base: ^common.D3D_App) {
	app := (^Waves_App)(base)

	on_keyboard_input(app)
	update_camera(app)

	// Cycle through the circular frame resource array.
	app.curr_frame_resource_index =
		(app.curr_frame_resource_index + 1) % common.NUM_FRAME_RESOURCES
	app.curr_frame_resource = &app.frame_resources[app.curr_frame_resource_index]

	// Has the GPU finished processing the commands of the current frame resource?
	// If not, wait until the GPU has completed commands up to this fence point.
	fr := app.curr_frame_resource
	if fr.fence != 0 && base.fence->GetCompletedValue() < fr.fence {
		event := win.CreateEventW(nil, false, false, nil)
		common.hr_panic(
			base.fence->SetEventOnCompletion(fr.fence, event),
			"SetEventOnCompletion(frame)",
		)
		win.WaitForSingleObject(event, win.INFINITE)
		win.CloseHandle(event)
	}

	update_per_object_cb(app)
	update_main_pass_cb(app)
	update_waves(app)
}

// C++: WavesApp::OnKeyboardInput — empty in this demo.
on_keyboard_input :: proc(app: ^Waves_App) {
}

// C++: WavesApp::UpdateCamera.
update_camera :: proc(app: ^Waves_App) {
	// Convert Spherical to Cartesian coordinates.
	app.eye_pos.x = app.radius * math.sin(app.phi) * math.cos(app.theta)
	app.eye_pos.z = app.radius * math.sin(app.phi) * math.sin(app.theta)
	app.eye_pos.y = app.radius * math.cos(app.phi)

	// Build the view matrix.
	pos := d3d_math.Vec3(app.eye_pos)
	target := d3d_math.Vec3{0, 0, 0}
	up := d3d_math.Vec3{0, 1, 0}
	app.view = d3d_math.look_at_lh(pos, target, up)
}

// C++: WavesApp::UpdatePerObjectCB.
update_per_object_cb :: proc(app: ^Waves_App) {
	// Update per object constants once per frame so the data can be shared across
	// different render passes.
	for ri in app.all_ritems {
		ri.object_cb.world = linalg.transpose(ri.world)

		// C++: Need to hold handle until we submit work to GPU.
		// Odin keeps the address for draw; submit-then-commit protects the page lifetime.
		ri.mem_handle_to_object_cb = common.allocate_constant(
			&app.linear_allocator,
			ri.object_cb,
		)
	}
}

// C++: WavesApp::UpdateMainPassCB.
update_main_pass_cb :: proc(app: ^Waves_App) {
	view_proj := app.view * app.proj // C++: view*proj — book order, preserved verbatim

	app.main_pass_cb.view_proj = linalg.transpose(view_proj)

	common.copy_data(&app.curr_frame_resource.pass_cb, 0, app.main_pass_cb)
}

// C++: WavesApp::UpdateWaves.
update_waves :: proc(app: ^Waves_App) {
	// Every quarter second, generate a random wave.
	if common.game_timer_total_time(&app.timer) - app.t_base >= 0.25 {
		app.t_base += 0.25

		// C++: MathHelper::Rand(a, b) — inclusive int range; RandF(a, b).
		i := 4 + rand.int_max(app.waves.num_rows - 5 - 4 + 1)
		j := 4 + rand.int_max(app.waves.num_cols - 5 - 4 + 1)

		r := app.wave_scale * rand.float32_range(0.3, 0.6)

		waves_disturb(&app.waves, i, j, r)
	}

	// Update the wave simulation.
	waves_update(&app.waves, common.game_timer_delta_time(&app.timer))

	// Update the wave vertex buffer with the new solution.
	curr_waves_vb := &app.curr_frame_resource.waves_vb
	verts := make([]Color_Vertex, app.waves.vertex_count, context.temp_allocator)
	for &v, i in verts {
		v.pos = app.waves.curr_solution[i]
		v.color = {0, 0, 1, 1} // C++: DirectX::Colors::Blue
	}
	common.copy_data_slice(curr_waves_vb, verts)

	// Set the dynamic VB of the wave renderitem to the current frame VB.
	// (A borrow — the C++ ComPtr assignment AddRefs; teardown nils this out, see main.)
	app.waves_ritem.geo.vertex_buffer_gpu = curr_waves_vb.upload_buffer
}

// C++: WavesApp::UpdateImgui — Options panel with the wave sliders.
update_imgui :: proc(app: ^Waves_App) {
	common.d3d_app_update_imgui_base() // C++: D3DApp::UpdateImgui(gt)

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

	im.Checkbox("Wireframe", &app.draw_wireframe)
	im.SliderFloat("WaveScale", &app.wave_scale, 0.25, 4.0)
	im.SliderFloat("WaveSpeed", &app.wave_speed, 2.0, 16.0)
	im.SliderFloat("WaveDamping", &app.wave_damping, 0.0, 3.0)

	waves_set_constants(&app.waves, app.wave_speed, app.wave_damping)

	gfx_mem_stats := common.get_statistics(&app.linear_allocator)

	if im.CollapsingHeader("VideoMemoryInfo") {
		app.video_mem_poll_time += common.game_timer_delta_time(&app.timer)
		if app.video_mem_poll_time >= 1.0 { 	// poll every second
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
	if im.CollapsingHeader("GraphicsMemoryStatistics") {
		im.Text("Bytes of memory in-flight: %llu", gfx_mem_stats.committed_memory)
		im.Text("Total bytes used: %llu", gfx_mem_stats.total_memory)
		im.Text("Total page count: %llu", gfx_mem_stats.total_pages)
	}

	im.End()

	im.Render()
}

// C++: WavesApp::Draw — frame-resource ring, no flush (see C7_Shapes).
draw :: proc(base: ^common.D3D_App) {
	app := (^Waves_App)(base)

	update_imgui(app)

	cmd_list_alloc := app.curr_frame_resource.cmd_list_alloc

	// Reuse the memory associated with command recording.
	// We can only reset when the associated command lists have finished execution on the GPU.
	common.hr_panic(cmd_list_alloc->Reset(), "CommandAllocator Reset")

	// A command list can be reset after it has been added to the command queue via
	// ExecuteCommandList. Reusing the command list reuses memory.
	common.hr_panic(
		base.command_list->Reset(cmd_list_alloc, app.psos["opaque"]),
		"CommandList Reset",
	)

	descriptor_heaps := [?]^d3d12.IDescriptorHeap{app.cbv_srv_uav_heap.heap}
	base.command_list->SetDescriptorHeaps(len(descriptor_heaps), &descriptor_heaps[0])

	base.command_list->SetGraphicsRootSignature(app.root_signature)

	base.command_list->RSSetViewports(1, &base.screen_viewport)
	base.command_list->RSSetScissorRects(1, &base.scissor_rect)

	// Indicate a state transition on the resource usage.
	to_render_target := common.transition_barrier(
		common.current_back_buffer(base),
		{}, // D3D12_RESOURCE_STATE_PRESENT
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

	pass_cb := app.curr_frame_resource.pass_cb.upload_buffer
	base.command_list->SetGraphicsRootConstantBufferView(
		u32(Root_Arg.PASS_CBV),
		pass_cb->GetGPUVirtualAddress(),
	)

	base.command_list->SetPipelineState(
		app.draw_wireframe ? app.psos["opaque_wireframe"] : app.psos["opaque"],
	)
	draw_render_items(app, app.ritem_layer[.Opaque][:])

	// Draw imgui UI.
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
	// C++: mLinearAllocator->Commit(mCommandQueue.Get());
	// Odin: submit first; our GPU-address handles do not retain pages like DirectXTK12's.
	common.commit(&app.linear_allocator, base.command_queue)

	// Swap the back and front buffers.
	present_params := dxgi.PRESENT_PARAMETERS{}
	common.hr_panic(base.swap_chain->Present1(0, {}, &present_params), "Present1")
	base.curr_back_buffer = (base.curr_back_buffer + 1) % common.SWAP_CHAIN_BUFFER_COUNT

	// Advance the fence value to mark commands up to this fence point.
	base.current_fence += 1
	app.curr_frame_resource.fence = base.current_fence

	// Add an instruction to the command queue to set a new fence point.
	// Because we are on the GPU timeline, the new fence point won't be
	// set until the GPU finishes processing all the commands prior to this Signal().
	base.command_queue->Signal(base.fence, base.current_fence)
}

// C++: WavesApp::DrawRenderItems.
draw_render_items :: proc(app: ^Waves_App, ritems: []^Render_Item) {
	cmd_list := app.command_list

	for ri in ritems {
		vbv := common.vertex_buffer_view(ri.geo)
		ibv := common.index_buffer_view(ri.geo)
		cmd_list->IASetVertexBuffers(0, 1, &vbv)
		cmd_list->IASetIndexBuffer(&ibv)
		cmd_list->IASetPrimitiveTopology(ri.primitive_type)

		cmd_list->SetGraphicsRootConstantBufferView(
			u32(Root_Arg.OBJECT_CBV),
			ri.mem_handle_to_object_cb.gpu_address,
		)

		cmd_list->DrawIndexedInstanced(
			ri.index_count,
			1,
			ri.start_index_location,
			ri.base_vertex_location,
			0,
		)
	}
}

// C++: WavesApp::OnMouseDown — ImGui gets first claim on the mouse.
on_mouse_down :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Waves_App)(base)
	io := im.GetIO()
	if !io.WantCaptureMouse {
		app.last_mouse_pos = {x, y}
		win.SetCapture(base.hwnd)
	}
}

// C++: WavesApp::OnMouseUp.
on_mouse_up :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	io := im.GetIO()
	if !io.WantCaptureMouse {
		win.ReleaseCapture()
	}
}

// C++: WavesApp::OnMouseMove — note the faster zoom (0.05/px) and wider radius clamp
// than the Shapes demo.
on_mouse_move :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Waves_App)(base)
	io := im.GetIO()
	if !io.WantCaptureMouse {
		if btn_state & win.MK_LBUTTON != 0 {
			// Make each pixel correspond to a quarter of a degree.
			dx := math.to_radians(0.25 * f32(x - app.last_mouse_pos.x))
			dy := math.to_radians(0.25 * f32(y - app.last_mouse_pos.y))

			// Update angles based on input to orbit camera around scene.
			app.theta += dx
			app.phi += dy

			// Restrict the angle mPhi.
			app.phi = clamp(app.phi, 0.1, math.PI - 0.1)
		} else if btn_state & win.MK_RBUTTON != 0 {
			// Make each pixel correspond to 0.05 unit in the scene.
			dx := 0.05 * f32(x - app.last_mouse_pos.x)
			dy := 0.05 * f32(y - app.last_mouse_pos.y)

			// Update the camera radius based on input.
			app.radius += dx - dy

			// Restrict the radius.
			app.radius = clamp(app.radius, 5.0, 150.0)
		}

		app.last_mouse_pos = {x, y}
	}
}

// C++: WavesApp::BuildCbvSrvUavDescriptorHeap.
build_cbv_srv_uav_descriptor_heap :: proc(app: ^Waves_App) {
	common.cbv_srv_uav_heap_init(&app.cbv_srv_uav_heap, app.device, CBV_SRV_UAV_HEAP_CAPACITY)
	common.d3d_app_init_imgui(&app.base, &app.cbv_srv_uav_heap)
}

// C++: WavesApp::BuildRootSignature — identical to C7_Shapes'.
build_root_signature :: proc(app: ^Waves_App) {
	// Root parameter can be a table, root descriptor or root constants.
	gfx_root_parameters: [Root_Arg]d3d12.ROOT_PARAMETER

	// C++: InitAsConstantBufferView(0) / (1).
	gfx_root_parameters[.OBJECT_CBV] = {
		ParameterType = .CBV,
		Descriptor = {ShaderRegister = 0, RegisterSpace = 0},
		ShaderVisibility = .ALL,
	}
	gfx_root_parameters[.PASS_CBV] = {
		ParameterType = .CBV,
		Descriptor = {ShaderRegister = 1, RegisterSpace = 0},
		ShaderVisibility = .ALL,
	}

	// A root signature is an array of root parameters.
	root_sig_desc := d3d12.ROOT_SIGNATURE_DESC {
		NumParameters = len(Root_Arg),
		pParameters   = &gfx_root_parameters[.OBJECT_CBV],
		Flags         = {.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT},
	}

	serialized_root_sig: ^d3d12.IBlob
	error_blob: ^d3d12.IBlob
	hr := d3d12.SerializeRootSignature(&root_sig_desc, ._1_0, &serialized_root_sig, &error_blob)

	if error_blob != nil {
		common.report_error(string(cstring(error_blob->GetBufferPointer())))
		error_blob->Release()
	}
	common.hr_panic(hr, "D3D12SerializeRootSignature")
	defer serialized_root_sig->Release()

	common.hr_panic(
		app.device->CreateRootSignature(
			0,
			serialized_root_sig->GetBufferPointer(),
			serialized_root_sig->GetBufferSize(),
			d3d12.IRootSignature_UUID,
			common.ptr(&app.root_signature),
		),
		"CreateRootSignature",
	)
}

// C++: WavesApp::BuildShadersAndInputLayout.
build_shaders_and_input_layout :: proc(app: ^Waves_App) {
	// C++: COMMA_DEBUG_ARGS — DXC_ARG_DEBUG, DXC_ARG_SKIP_OPTIMIZATIONS in debug builds.
	when ODIN_DEBUG {
		vs_args := [?]string{"-E", "VS", "-T", "vs_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
		ps_args := [?]string{"-E", "PS", "-T", "ps_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
	} else {
		vs_args := [?]string{"-E", "VS", "-T", "vs_6_6"}
		ps_args := [?]string{"-E", "PS", "-T", "ps_6_6"}
	}

	app.shaders["standardVS"] = common.compile_shader("Shaders/BasicColor.hlsl", vs_args[:])
	app.shaders["opaquePS"] = common.compile_shader("Shaders/BasicColor.hlsl", ps_args[:])

	app.input_layout = {
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .PER_VERTEX_DATA, 0},
		{"COLOR", 0, .R32G32B32A32_FLOAT, 0, 12, .PER_VERTEX_DATA, 0},
	}
}

// C++: WavesApp::BuildPSOs.
build_psos :: proc(app: ^Waves_App) {
	base_pso_desc := common.init_default_pso(
		app.back_buffer_format,
		app.depth_stencil_format,
		app.input_layout[:],
		app.root_signature,
		app.shaders["standardVS"],
		app.shaders["opaquePS"],
	)

	opaque: ^d3d12.IPipelineState
	common.hr_panic(
		app.device->CreateGraphicsPipelineState(
			&base_pso_desc,
			d3d12.IPipelineState_UUID,
			common.ptr(&opaque),
		),
		"CreateGraphicsPipelineState(opaque)",
	)
	app.psos["opaque"] = opaque

	wireframe_pso_desc := base_pso_desc
	wireframe_pso_desc.RasterizerState.FillMode = .WIREFRAME

	wireframe: ^d3d12.IPipelineState
	common.hr_panic(
		app.device->CreateGraphicsPipelineState(
			&wireframe_pso_desc,
			d3d12.IPipelineState_UUID,
			common.ptr(&wireframe),
		),
		"CreateGraphicsPipelineState(opaque_wireframe)",
	)
	app.psos["opaque_wireframe"] = wireframe
}

// C++: WavesApp::BuildFrameResources.
build_frame_resources :: proc(app: ^Waves_App) {
	pass_count :: 1
	for &fr in app.frame_resources {
		frame_resource_init(&fr, app.device, pass_count, u32(app.waves.vertex_count))
	}
}

// C++: WavesApp::AddRenderItem.
add_render_item :: proc(
	app: ^Waves_App,
	layer: Render_Layer,
	world: d3d_math.Mat4,
	geo: ^common.Mesh_Geometry,
	draw_args: common.Submesh_Geometry,
) {
	ritem := new(Render_Item)
	ritem.world = world
	ritem.tex_transform = d3d_math.MAT4_IDENTITY
	ritem.geo = geo
	ritem.primitive_type = .TRIANGLELIST
	ritem.index_count = draw_args.index_count
	ritem.start_index_location = draw_args.start_index_location
	ritem.base_vertex_location = draw_args.base_vertex_location

	append(&app.ritem_layer[layer], ritem)
	append(&app.all_ritems, ritem)
}

// C++: WavesApp::BuildRenderItems — the water grid and the land grid, both at identity.
build_render_items :: proc(app: ^Waves_App) {
	water_geo := app.geometries["waterGeo"]
	add_render_item(app, .Opaque, d3d_math.MAT4_IDENTITY, water_geo, water_geo.draw_args["grid"])
	app.waves_ritem = app.all_ritems[len(app.all_ritems) - 1]

	land_geo := app.geometries["landGeo"]
	add_render_item(app, .Opaque, d3d_math.MAT4_IDENTITY, land_geo, land_geo.draw_args["grid"])
}

// C++: WavesApp::BuildLandGeometry — a grid with the hills height function applied, and
// vertices colored by height: sandy beaches, grassy low hills, snow mountain peaks.
build_land_geometry :: proc(
	app: ^Waves_App,
	upload_batch: ^common.Resource_Upload_Batch,
) -> ^common.Mesh_Geometry {
	grid := common.create_grid(160.0, 160.0, 50, 50)
	defer common.mesh_gen_data_destroy(&grid)

	//
	// Extract the vertex elements we are interested and apply the height function to
	// each vertex.  In addition, color the vertices based on their height so we have
	// sandy looking beaches, grassy low hills, and snow mountain peaks.
	//

	vertices := make([]Color_Vertex, len(grid.vertices))
	defer delete(vertices)
	for &v, i in vertices {
		p := grid.vertices[i].position
		v.pos = p
		v.pos.y = get_hills_height(p.x, p.z)

		// Color the vertex based on its height.
		switch {
		case v.pos.y < -10.0:
			v.color = {1.0, 0.96, 0.62, 1.0} // Sandy beach color.
		case v.pos.y < 5.0:
			v.color = {0.48, 0.77, 0.46, 1.0} // Light yellow-green.
		case v.pos.y < 12.0:
			v.color = {0.1, 0.48, 0.19, 1.0} // Dark yellow-green.
		case v.pos.y < 20.0:
			v.color = {0.45, 0.39, 0.34, 1.0} // Dark brown.
		case:
			v.color = {1.0, 1.0, 1.0, 1.0} // White snow.
		}
	}

	indices := common.get_indices16(&grid)
	defer delete(indices)

	vb_byte_size := u32(len(vertices) * size_of(Color_Vertex))
	ib_byte_size := u32(len(indices) * size_of(u16))

	geo := new(common.Mesh_Geometry)
	geo.name = "landGeo"

	geo.vertex_buffer_cpu = slice.clone(slice.to_bytes(vertices))
	geo.index_buffer_cpu = slice.clone(slice.to_bytes(indices))

	common.create_static_buffer(
		upload_batch,
		raw_data(vertices),
		len(vertices),
		size_of(Color_Vertex),
		{.VERTEX_AND_CONSTANT_BUFFER},
		&geo.vertex_buffer_gpu,
	)

	common.create_static_buffer(
		upload_batch,
		raw_data(indices),
		len(indices),
		size_of(u16),
		{.INDEX_BUFFER},
		&geo.index_buffer_gpu,
	)

	geo.vertex_byte_stride = size_of(Color_Vertex)
	geo.vertex_buffer_byte_size = vb_byte_size
	geo.index_format = .R16_UINT
	geo.index_buffer_byte_size = ib_byte_size

	geo.draw_args["grid"] = common.Submesh_Geometry {
		index_count          = u32(len(indices)),
		start_index_location = 0,
		base_vertex_location = 0,
		vertex_count         = u32(len(vertices)),
	}

	return geo
}

// C++: WavesApp::BuildWaveGeometry — static 32-bit indices, matching the book.
// 128*128 = 16384 vertices fit in 16 bits; this choice preserves reference behavior.
// The vertex buffer stays nil and is pointed at the current frame resource's
// dynamic VB every frame in update_waves.
build_wave_geometry :: proc(
	app: ^Waves_App,
	upload_batch: ^common.Resource_Upload_Batch,
) -> ^common.Mesh_Geometry {
	indices := make([]u32, 3 * app.waves.triangle_count) // 3 indices per face
	defer delete(indices)

	// Iterate over each quad.
	m := app.waves.num_rows
	n := app.waves.num_cols
	k := 0
	for i in 0 ..< m - 1 {
		for j in 0 ..< n - 1 {
			indices[k] = u32(i * n + j)
			indices[k + 1] = u32(i * n + j + 1)
			indices[k + 2] = u32((i + 1) * n + j)

			indices[k + 3] = u32((i + 1) * n + j)
			indices[k + 4] = u32(i * n + j + 1)
			indices[k + 5] = u32((i + 1) * n + j + 1)

			k += 6 // next quad
		}
	}

	vb_byte_size := u32(app.waves.vertex_count * size_of(Color_Vertex))
	ib_byte_size := u32(len(indices) * size_of(u32))

	geo := new(common.Mesh_Geometry)
	geo.name = "waterGeo"

	// Set dynamically every frame in update_waves.
	geo.vertex_buffer_cpu = nil
	geo.vertex_buffer_gpu = nil

	geo.index_buffer_cpu = slice.clone(slice.to_bytes(indices))

	common.create_static_buffer(
		upload_batch,
		raw_data(indices),
		len(indices),
		size_of(u32),
		{.INDEX_BUFFER},
		&geo.index_buffer_gpu,
	)

	geo.vertex_byte_stride = size_of(Color_Vertex)
	geo.vertex_buffer_byte_size = vb_byte_size
	geo.index_format = .R32_UINT
	geo.index_buffer_byte_size = ib_byte_size

	geo.draw_args["grid"] = common.Submesh_Geometry {
		index_count          = u32(len(indices)),
		start_index_location = 0,
		base_vertex_location = 0,
	}

	return geo
}

// C++: WavesApp::GetHillsHeight.
get_hills_height :: proc(x, z: f32) -> f32 {
	return 0.3 * (z * math.sin(0.1 * x) + x * math.cos(0.1 * z))
}

// C++: WavesApp::GetHillsNormal — unused until the lighting chapter, kept for parity.
get_hills_normal :: proc(x, z: f32) -> [3]f32 {
	// n = (-df/dx, 1, -df/dz)
	n := [3]f32 {
		-0.03 * z * math.cos(0.1 * x) - 0.3 * math.cos(0.1 * z),
		1.0,
		-0.3 * math.sin(0.1 * x) + 0.03 * x * math.sin(0.1 * z),
	}
	return linalg.normalize(n)
}
