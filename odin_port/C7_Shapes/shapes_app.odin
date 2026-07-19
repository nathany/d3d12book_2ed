// Port of `Demos/C7_Shapes` (ShapesApp.cpp/.h) — chapter 7's first demo. What's new over
// chapter 6, and why this chapter matters:
//
//  - The **FrameResource ring** (NUM_FRAME_RESOURCES deep): per-frame command allocator +
//    per-frame pass CB + a fence value. Draw no longer flushes; Update waits only if the
//    GPU is more than a full ring behind. This is the book's core CPU/GPU parallelism
//    idiom (~3x the fps of the flush-per-frame ch 6 demos here).
//  - **Render items**: one list describing every object (world matrix + geometry +
//    draw args), drawn by a shared DrawRenderItems loop.
//  - **Per-object constants from the linear upload arena** (common/graphics_memory.odin,
//    the DirectXTK12 GraphicsMemory port): allocate_constant per item per frame, commit
//    once per frame — no per-object CBVs; the root signature uses **root descriptors**
//    (SetGraphicsRootConstantBufferView) instead of descriptor tables.
//  - **MeshGen** (common/mesh_gen.odin): box/grid/sphere/cylinder concatenated into one
//    vertex/index buffer pair, drawn via per-submesh offsets.
//
// Build & run FROM THE REPO ROOT (shader path + DXC DLLs are resolved relative to it):
//   odin run odin_port/C7_Shapes -debug
package c7_shapes

import "core:math"
import "core:math/linalg"
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

// C++: struct ColorVertex { XMFLOAT3 Pos; XMFLOAT4 Color; };
Color_Vertex :: struct {
	pos:   [3]f32,
	color: [4]f32,
}

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

// Lightweight structure stores parameters to draw a shape.  This will
// vary from app-to-app.
Render_Item :: struct {
	// World matrix of the shape that describes the object's local space
	// relative to the world space.
	world:                   d3d_math.Mat4,
	tex_transform:           d3d_math.Mat4,

	// Per object constant data.
	object_cb:               Object_Constants,

	// Handle to per-object memory in linear allocator.
	mem_handle_to_object_cb: common.Graphics_Resource,

	// mat: ^Material — arrives in ch 8.
	geo:                     ^common.Mesh_Geometry,

	// Primitive topology.
	primitive_type:          d3d12.PRIMITIVE_TOPOLOGY,

	// DrawIndexedInstanced parameters.
	index_count:             u32,
	start_index_location:    u32,
	base_vertex_location:    i32,
}

Shapes_App :: struct {
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

	// List of all the render items.
	all_ritems:                [dynamic]^Render_Item,

	// Render items divided by PSO.
	ritem_layer:               [Render_Layer][dynamic]^Render_Item,

	main_pass_cb:              Pass_Constants,

	view:                      d3d_math.Mat4,
	proj:                      d3d_math.Mat4,

	eye_pos:                   [3]f32,
	theta:                     f32,
	phi:                       f32,
	radius:                    f32,

	last_mouse_pos:            [2]i32, // C++: POINT mLastMousePos

	draw_wireframe:            bool,

	video_mem_poll_time:       f32,
	video_mem_info:            dxgi.QUERY_VIDEO_MEMORY_INFO,
}

main :: proc() {
	context = common.mem_track_init() // Odin-side leak detection (debug builds); see common/mem_track.odin

	app: Shapes_App

	// C++ member initializers (ShapesApp.h) — note wireframe starts ON in this demo.
	app.view = d3d_math.MAT4_IDENTITY
	app.proj = d3d_math.MAT4_IDENTITY
	app.theta = 1.5 * math.PI
	app.phi = 0.35 * math.PI
	app.radius = 20.0
	app.draw_wireframe = true

	app.update = update
	app.draw = draw
	app.on_resize = on_resize
	app.on_mouse_down = on_mouse_down
	app.on_mouse_up = on_mouse_up
	app.on_mouse_move = on_mouse_move

	// C++: ShapesApp::Initialize().
	common.d3d_app_init(&app.base)

	// We will upload on the direct queue for the book samples, but
	// copy queue would be better for real game.
	upload_batch: common.Resource_Upload_Batch
	common.upload_batch_begin(&upload_batch, app.device)

	shape_geo := build_shape_geometry(&app, &upload_batch)
	app.geometries[shape_geo.name] = shape_geo

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
	for _, geo in app.geometries {common.mesh_geometry_destroy(geo);free(geo)}
	delete(app.geometries)
	common.cbv_srv_uav_heap_destroy(&app.cbv_srv_uav_heap)
	common.d3d_app_shutdown(&app.base)
	common.mem_track_report() // before os.exit — os.exit skips defers
	os.exit(code)
}

// C++: ShapesApp::OnResize.
on_resize :: proc(base: ^common.D3D_App) {
	app := (^Shapes_App)(base)

	common.on_resize(base) // C++: D3DApp::OnResize();

	// The window resized, so update the aspect ratio and recompute the projection matrix.
	app.proj = d3d_math.perspective_fov_lh(
		0.25 * math.PI,
		common.aspect_ratio(base),
		1.0,
		1000.0,
	)
}

// C++: ShapesApp::Update.
update :: proc(base: ^common.D3D_App) {
	app := (^Shapes_App)(base)

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
}

// C++: ShapesApp::OnKeyboardInput — empty in this demo.
on_keyboard_input :: proc(app: ^Shapes_App) {
}

// C++: ShapesApp::UpdateCamera.
update_camera :: proc(app: ^Shapes_App) {
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

// C++: ShapesApp::UpdatePerObjectCB.
update_per_object_cb :: proc(app: ^Shapes_App) {
	// Update per object constants once per frame so the data can be shared across
	// different render passes.
	for ri in app.all_ritems {
		ri.object_cb.world = linalg.transpose(ri.world)

		// Need to hold handle until we submit work to GPU (the arena page stays alive
		// until commit's fence retires it — see graphics_memory.odin).
		ri.mem_handle_to_object_cb = common.allocate_constant(
			&app.linear_allocator,
			ri.object_cb,
		)
	}
}

// C++: ShapesApp::UpdateMainPassCB.
update_main_pass_cb :: proc(app: ^Shapes_App) {
	view_proj := app.view * app.proj // C++: view*proj — book order, preserved verbatim

	app.main_pass_cb.view_proj = linalg.transpose(view_proj)

	common.copy_data(&app.curr_frame_resource.pass_cb, 0, app.main_pass_cb)
}

// C++: ShapesApp::UpdateImgui — the "Options" panel, now with the linear allocator's
// GraphicsMemoryStatistics section (present in the C++ since ch 4; ours had to wait for
// the arena to exist).
update_imgui :: proc(app: ^Shapes_App) {
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

// C++: ShapesApp::Draw — NOTE: no FlushCommandQueue at the end anymore; the frame
// resource's fence value replaces it (the whole point of this chapter).
draw :: proc(base: ^common.D3D_App) {
	app := (^Shapes_App)(base)

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

	// Pass constants: a root descriptor now — no CBV/heap involved.
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

	// C++: mLinearAllocator->Commit(mCommandQueue.Get());
	common.commit(&app.linear_allocator, base.command_queue)

	// Add the command list to the queue for execution.
	cmd_lists := [?]^d3d12.ICommandList{(^d3d12.ICommandList)(base.command_list)}
	base.command_queue->ExecuteCommandLists(len(cmd_lists), &cmd_lists[0])

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

// C++: ShapesApp::DrawRenderItems.
draw_render_items :: proc(app: ^Shapes_App, ritems: []^Render_Item) {
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

// C++: ShapesApp::OnMouseDown — ImGui gets first claim on the mouse.
on_mouse_down :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Shapes_App)(base)
	io := im.GetIO()
	if !io.WantCaptureMouse {
		app.last_mouse_pos = {x, y}
		win.SetCapture(base.hwnd)
	}
}

// C++: ShapesApp::OnMouseUp.
on_mouse_up :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	io := im.GetIO()
	if !io.WantCaptureMouse {
		win.ReleaseCapture()
	}
}

// C++: ShapesApp::OnMouseMove.
on_mouse_move :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Shapes_App)(base)
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
			// Make each pixel correspond to 0.005 unit in the scene.
			dx := 0.005 * f32(x - app.last_mouse_pos.x)
			dy := 0.005 * f32(y - app.last_mouse_pos.y)

			// Update the camera radius based on input.
			app.radius += dx - dy

			// Restrict the radius.
			app.radius = clamp(app.radius, 5.0, 25.0)
		}

		app.last_mouse_pos = {x, y}
	}
}

// C++: ShapesApp::BuildCbvSrvUavDescriptorHeap.
build_cbv_srv_uav_descriptor_heap :: proc(app: ^Shapes_App) {
	common.cbv_srv_uav_heap_init(&app.cbv_srv_uav_heap, app.device, CBV_SRV_UAV_HEAP_CAPACITY)
	common.d3d_app_init_imgui(&app.base, &app.cbv_srv_uav_heap)
}

// C++: ShapesApp::BuildRootSignature — root CBVs (root descriptors), not tables.
build_root_signature :: proc(app: ^Shapes_App) {
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

// C++: ShapesApp::BuildShadersAndInputLayout.
build_shaders_and_input_layout :: proc(app: ^Shapes_App) {
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

// C++: ShapesApp::BuildPSOs.
build_psos :: proc(app: ^Shapes_App) {
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

// C++: ShapesApp::BuildFrameResources.
build_frame_resources :: proc(app: ^Shapes_App) {
	pass_count :: 1
	for &fr in app.frame_resources {
		frame_resource_init(&fr, app.device, pass_count)
	}
}

// C++: ShapesApp::AddRenderItem.
add_render_item :: proc(
	app: ^Shapes_App,
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

// C++: ShapesApp::BuildRenderItems — one box, one grid, and two rows of five
// cylinder+sphere pairs marching down the z-axis.
build_render_items :: proc(app: ^Shapes_App) {
	geo := app.geometries["shapeGeo"]

	world := d3d_math.scaling(2.0, 1.0, 2.0) * d3d_math.translation(0.0, 0.5, 0.0)
	add_render_item(app, .Opaque, world, geo, geo.draw_args["box"])

	add_render_item(app, .Opaque, d3d_math.MAT4_IDENTITY, geo, geo.draw_args["grid"])

	for i in 0 ..< 5 {
		z := -10.0 + f32(i) * 5.0
		add_render_item(app, .Opaque, d3d_math.translation(-5.0, 1.5, z), geo, geo.draw_args["cylinder"])
		add_render_item(app, .Opaque, d3d_math.translation(+5.0, 1.5, z), geo, geo.draw_args["cylinder"])
		add_render_item(app, .Opaque, d3d_math.translation(-5.0, 3.5, z), geo, geo.draw_args["sphere"])
		add_render_item(app, .Opaque, d3d_math.translation(+5.0, 3.5, z), geo, geo.draw_args["sphere"])
	}
}

// C++: ShapesApp::BuildShapeGeometry — concatenate all the shapes into one big
// vertex/index buffer and record the submesh regions.
build_shape_geometry :: proc(
	app: ^Shapes_App,
	upload_batch: ^common.Resource_Upload_Batch,
) -> ^common.Mesh_Geometry {
	box := common.create_box(1.0, 1.0, 1.0, 3)
	grid := common.create_grid(20.0, 30.0, 60, 40)
	sphere := common.create_sphere(0.5, 20, 20)
	cylinder := common.create_cylinder(0.5, 0.3, 3.0, 20, 20)
	quad := common.create_quad(0.0, 0.0, 1.0, 1.0, 0.0)
	defer {
		common.mesh_gen_data_destroy(&box)
		common.mesh_gen_data_destroy(&grid)
		common.mesh_gen_data_destroy(&sphere)
		common.mesh_gen_data_destroy(&cylinder)
		common.mesh_gen_data_destroy(&quad)
	}

	//
	// We are concatenating all the geometry into one big vertex/index buffer.  So
	// define the regions in the buffer each submesh covers.
	//
	composite_mesh: common.Mesh_Gen_Data
	defer common.mesh_gen_data_destroy(&composite_mesh)
	box_submesh := common.append_submesh(&composite_mesh, &box)
	grid_submesh := common.append_submesh(&composite_mesh, &grid)
	sphere_submesh := common.append_submesh(&composite_mesh, &sphere)
	cylinder_submesh := common.append_submesh(&composite_mesh, &cylinder)
	quad_submesh := common.append_submesh(&composite_mesh, &quad)

	color := [4]f32{0.2, 0.2, 0.2, 1.0}

	// Extract the vertex elements we are interested into our vertex buffer.
	vertices := make([]Color_Vertex, len(composite_mesh.vertices))
	defer delete(vertices)
	for &v, i in vertices {
		v.pos = composite_mesh.vertices[i].position
		v.color = color
	}

	indices := common.get_indices16(&composite_mesh)
	defer delete(indices)

	vb_byte_size := u32(len(vertices) * size_of(Color_Vertex))
	ib_byte_size := u32(len(indices) * size_of(u16))

	geo := new(common.Mesh_Geometry)
	geo.name = "shapeGeo"

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

	geo.draw_args["box"] = box_submesh
	geo.draw_args["grid"] = grid_submesh
	geo.draw_args["sphere"] = sphere_submesh
	geo.draw_args["cylinder"] = cylinder_submesh
	geo.draw_args["quad"] = quad_submesh

	return geo
}
