// Port of `Demos/C8_LitShapes` (LitShapesApp.cpp/.h) — chapter 8's first demo: the ch 7
// shapes scene, lit. What's new over chapter 7:
//
//  - **Lighting**: the full ModelVertex (position/normal/texcoord/tangent) replaces the
//    per-vertex color, and Shaders/BasicLit.hlsl evaluates three rotating directional
//    lights (Blinn-Phong + Schlick Fresnel from LightingUtil.hlsl) per pixel.
//  - **Materials**: a CPU-side Material table uploaded into a per-frame StructuredBuffer,
//    bound once per frame as a **root SRV** (no descriptor heap involved); each object's
//    PerObjectCB carries an index into it, and a NumFramesDirty counter propagates edits
//    through the frame-resource ring.
//  - **The shared cbuffer layouts**: the demo now binds the real Shaders/SharedTypes.h
//    structs (common/shared_types.odin) — full PerObjectCB/PerPassCB, not trimmed ones.
//  - **The skull**: Models/skull.txt loaded by common.build_skull_geometry.
//
// Build & run FROM THE REPO ROOT (shader path + DXC DLLs are resolved relative to it):
//   odin run odin_port/C8_LitShapes -debug
package c8_litshapes

import "core:math"
import "core:math/linalg"
import "core:os"
import win "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxc "vendor:directx/dxc"
import dxgi "vendor:directx/dxgi"
import common "../common"
import "../d3d_math"
import im "../libs/imgui"
import im_dx12 "../libs/imgui/backends/dx12"

// C++: DirectX::Colors used by this demo.
LIGHT_STEEL_BLUE :: [4]f32{0.690196097, 0.768627524, 0.870588303, 1.0}
FOREST_GREEN :: [4]f32{0.133333340, 0.545098066, 0.133333340, 1.0}
STEEL_BLUE :: [4]f32{0.274509817, 0.509803951, 0.705882370, 1.0}
LIGHT_GRAY :: [4]f32{0.827451050, 0.827451050, 0.827451050, 1.0}

// C++: constexpr UINT CBV_SRV_UAV_HEAP_CAPACITY = 16384;
CBV_SRV_UAV_HEAP_CAPACITY :: 16384

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

	// Per object constant data (the full shared-header struct now).
	object_cb:               common.Per_Object_CB,

	// Handle to per-object memory in linear allocator.
	mem_handle_to_object_cb: common.Graphics_Resource,

	mat:                     ^common.Material,
	geo:                     ^common.Mesh_Geometry,

	// Primitive topology.
	primitive_type:          d3d12.PRIMITIVE_TOPOLOGY,

	// DrawIndexedInstanced parameters.
	index_count:             u32,
	start_index_location:    u32,
	base_vertex_location:    i32,
}

Lit_Shapes_App :: struct {
	using base:                common.D3D_App,
	cbv_srv_uav_heap:          common.Cbv_Srv_Uav_Heap,

	frame_resources:           [common.NUM_FRAME_RESOURCES]Frame_Resource,
	curr_frame_resource:       ^Frame_Resource,
	curr_frame_resource_index: int,

	root_signature:            ^d3d12.IRootSignature,

	geometries:                map[string]^common.Mesh_Geometry,
	shaders:                   map[string]^dxc.IBlob,
	materials:                 map[string]^common.Material,
	psos:                      map[string]^d3d12.IPipelineState,

	input_layout:              [4]d3d12.INPUT_ELEMENT_DESC,

	// List of all the render items.
	all_ritems:                [dynamic]^Render_Item,

	// Render items divided by PSO.
	ritem_layer:               [Render_Layer][dynamic]^Render_Item,

	main_pass_cb:              common.Per_Pass_CB,

	view:                      d3d_math.Mat4,
	proj:                      d3d_math.Mat4,

	eye_pos:                   [3]f32,
	theta:                     f32,
	phi:                       f32,
	radius:                    f32,

	light_rotation_angle:      f32,
	base_light_directions:     [3][3]f32,
	rotated_light_directions:  [3][3]f32,

	last_mouse_pos:            [2]i32, // C++: POINT mLastMousePos

	draw_wireframe:            bool,

	next_mat_index:            i32, // C++: the matIndex captured by the AddMaterial lambda

	video_mem_poll_time:       f32,
	video_mem_info:            dxgi.QUERY_VIDEO_MEMORY_INFO,
}

main :: proc() {
	context = common.mem_track_init() // Odin-side leak detection (debug builds); see common/mem_track.odin

	app: Lit_Shapes_App

	// C++ member initializers (LitShapesApp.h) — wireframe starts OFF in this demo (we
	// want to see the lighting).
	app.view = d3d_math.MAT4_IDENTITY
	app.proj = d3d_math.MAT4_IDENTITY
	app.theta = 1.5 * math.PI
	app.phi = 0.35 * math.PI
	app.radius = 20.0
	app.draw_wireframe = false
	app.base_light_directions = {
		{0.57735, -0.57735, 0.57735},
		{-0.57735, -0.57735, 0.57735},
		{0.0, -0.707, -0.707},
	}

	app.update = update
	app.draw = draw
	app.on_resize = on_resize
	app.on_mouse_down = on_mouse_down
	app.on_mouse_up = on_mouse_up
	app.on_mouse_move = on_mouse_move

	// C++: LitShapesApp::Initialize().
	common.d3d_app_init(&app.base)

	// We will upload on the direct queue for the book samples, but
	// copy queue would be better for real game.
	upload_batch: common.Resource_Upload_Batch
	common.upload_batch_begin(&upload_batch, app.device)

	shape_geo := common.build_shape_geometry(&upload_batch)
	app.geometries[shape_geo.name] = shape_geo

	skull_geo := common.build_skull_geometry(&upload_batch)
	app.geometries[skull_geo.name] = skull_geo

	// (C++ overlaps the upload with the rest of init via std::future; see C6_Box.)
	common.upload_batch_end_and_wait(&upload_batch, app.command_queue)

	// Other init work...
	build_root_signature(&app)
	build_cbv_srv_uav_descriptor_heap(&app)
	build_shaders_and_input_layout(&app)
	build_materials(&app)
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
	for _, mat in app.materials {free(mat)}
	delete(app.materials)
	for _, geo in app.geometries {common.mesh_geometry_destroy(geo);free(geo)}
	delete(app.geometries)
	common.cbv_srv_uav_heap_destroy(&app.cbv_srv_uav_heap)
	common.d3d_app_shutdown(&app.base)
	common.mem_track_report() // before os.exit — os.exit skips defers
	os.exit(code)
}

// C++: LitShapesApp::OnResize.
on_resize :: proc(base: ^common.D3D_App) {
	app := (^Lit_Shapes_App)(base)

	common.on_resize(base) // C++: D3DApp::OnResize();

	// The window resized, so update the aspect ratio and recompute the projection matrix.
	app.proj = d3d_math.perspective_fov_lh(
		0.25 * math.PI,
		common.aspect_ratio(base),
		1.0,
		1000.0,
	)
}

// C++: LitShapesApp::Update.
update :: proc(base: ^common.D3D_App) {
	app := (^Lit_Shapes_App)(base)

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

	//
	// Animate the lights.
	//

	app.light_rotation_angle += 0.1 * common.game_timer_delta_time(&app.timer)

	r := d3d_math.rotation_y(app.light_rotation_angle)
	for dir, i in app.base_light_directions {
		// C++: XMVector3TransformNormal(lightDir, R).
		app.rotated_light_directions[i] = d3d_math.transform_normal(dir, r)
	}

	animate_materials(app)
	update_per_object_cb(app)
	update_material_buffer(app)
	update_main_pass_cb(app)
}

// C++: LitShapesApp::OnKeyboardInput — empty in this demo.
on_keyboard_input :: proc(app: ^Lit_Shapes_App) {
}

// C++: LitShapesApp::AnimateMaterials — empty in this demo.
animate_materials :: proc(app: ^Lit_Shapes_App) {
}

// C++: LitShapesApp::UpdateCamera.
update_camera :: proc(app: ^Lit_Shapes_App) {
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

// C++: LitShapesApp::UpdatePerObjectCB.
update_per_object_cb :: proc(app: ^Lit_Shapes_App) {
	// Update per object constants once per frame so the data can be shared across
	// different render passes.
	for ri in app.all_ritems {
		ri.object_cb.world = linalg.transpose(ri.world)
		ri.object_cb.tex_transform = linalg.transpose(ri.tex_transform)
		ri.object_cb.material_index = u32(ri.mat.mat_index)

		// C++: Need to hold handle until we submit work to GPU.
		// Odin keeps the address for draw; submit-then-commit protects the page lifetime.
		ri.mem_handle_to_object_cb = common.allocate_constant(
			&app.linear_allocator,
			ri.object_cb,
		)
	}
}

// C++: LitShapesApp::UpdateMaterialBuffer.
update_material_buffer :: proc(app: ^Lit_Shapes_App) {
	curr_material_buffer := &app.curr_frame_resource.material_buffer
	for _, mat in app.materials {
		// Only update the buffer data if the data has changed.  If the buffer
		// data changes, it needs to be updated for each FrameResource.
		if mat.num_frames_dirty > 0 {
			mat_data: common.Material_Data
			mat_data.diffuse_albedo = mat.diffuse_albedo
			mat_data.fresnel_r0 = mat.fresnel_r0
			mat_data.roughness = mat.roughness

			common.copy_data(curr_material_buffer, int(mat.mat_index), mat_data)

			// Next FrameResource need to be updated too.
			mat.num_frames_dirty -= 1
		}
	}
}

// C++: LitShapesApp::UpdateMainPassCB — fills the full shared PerPassCB now: the inverse
// matrices, eye position, ambient light, and the three directional lights.
update_main_pass_cb :: proc(app: ^Lit_Shapes_App) {
	app.main_pass_cb = {} // C++: ZeroMemory(&mMainPassCB, sizeof(mMainPassCB));

	view := app.view
	proj := app.proj

	view_proj := view * proj // C++: view*proj — book order, preserved verbatim
	inv_view := linalg.inverse(view)
	inv_proj := linalg.inverse(proj)
	inv_view_proj := linalg.inverse(view_proj)

	cb := &app.main_pass_cb
	cb.view = linalg.transpose(view)
	cb.inv_view = linalg.transpose(inv_view)
	cb.proj = linalg.transpose(proj)
	cb.inv_proj = linalg.transpose(inv_proj)
	cb.view_proj = linalg.transpose(view_proj)
	cb.inv_view_proj = linalg.transpose(inv_view_proj)
	cb.eye_pos_w = app.eye_pos
	cb.render_target_size = {f32(app.client_width), f32(app.client_height)}
	cb.inv_render_target_size = {1.0 / f32(app.client_width), 1.0 / f32(app.client_height)}
	cb.near_z = 1.0
	cb.far_z = 1000.0
	cb.total_time = common.game_timer_total_time(&app.timer)
	cb.delta_time = common.game_timer_delta_time(&app.timer)
	cb.ambient_light = {0.25, 0.25, 0.35, 1.0}

	cb.num_dir_lights = 3
	cb.num_point_lights = 0
	cb.num_spot_lights = 0

	cb.lights[0].direction = app.rotated_light_directions[0]
	cb.lights[0].strength = {0.9, 0.8, 0.7}
	cb.lights[1].direction = app.rotated_light_directions[1]
	cb.lights[1].strength = {0.4, 0.4, 0.4}
	cb.lights[2].direction = app.rotated_light_directions[2]
	cb.lights[2].strength = {0.2, 0.2, 0.2}

	common.copy_data(&app.curr_frame_resource.pass_cb, 0, app.main_pass_cb)
}

// C++: LitShapesApp::UpdateImgui — the "Options" panel.
update_imgui :: proc(app: ^Lit_Shapes_App) {
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

// C++: LitShapesApp::Draw.
draw :: proc(base: ^common.D3D_App) {
	app := (^Lit_Shapes_App)(base)

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

	// Bind all the materials used in this scene.  For structured buffers, we can bypass
	// the heap and set as a root descriptor.
	mat_buffer := app.curr_frame_resource.material_buffer.upload_buffer
	base.command_list->SetGraphicsRootShaderResourceView(
		u32(Gfx_Root_Arg.MATERIAL_SRV),
		mat_buffer->GetGPUVirtualAddress(),
	)

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

	// Pass constants: a root descriptor — no CBV/heap involved.
	pass_cb := app.curr_frame_resource.pass_cb.upload_buffer
	base.command_list->SetGraphicsRootConstantBufferView(
		u32(Gfx_Root_Arg.PASS_CBV),
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

// C++: LitShapesApp::DrawRenderItems.
draw_render_items :: proc(app: ^Lit_Shapes_App, ritems: []^Render_Item) {
	cmd_list := app.command_list

	for ri in ritems {
		vbv := common.vertex_buffer_view(ri.geo)
		ibv := common.index_buffer_view(ri.geo)
		cmd_list->IASetVertexBuffers(0, 1, &vbv)
		cmd_list->IASetIndexBuffer(&ibv)
		cmd_list->IASetPrimitiveTopology(ri.primitive_type)

		cmd_list->SetGraphicsRootConstantBufferView(
			u32(Gfx_Root_Arg.OBJECT_CBV),
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

// C++: LitShapesApp::OnMouseDown — ImGui gets first claim on the mouse.
on_mouse_down :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Lit_Shapes_App)(base)
	io := im.GetIO()
	if !io.WantCaptureMouse {
		app.last_mouse_pos = {x, y}
		win.SetCapture(base.hwnd)
	}
}

// C++: LitShapesApp::OnMouseUp.
on_mouse_up :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	io := im.GetIO()
	if !io.WantCaptureMouse {
		win.ReleaseCapture()
	}
}

// C++: LitShapesApp::OnMouseMove.
on_mouse_move :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Lit_Shapes_App)(base)
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

// C++: LitShapesApp::BuildCbvSrvUavDescriptorHeap.
build_cbv_srv_uav_descriptor_heap :: proc(app: ^Lit_Shapes_App) {
	common.cbv_srv_uav_heap_init(&app.cbv_srv_uav_heap, app.device, CBV_SRV_UAV_HEAP_CAPACITY)
	common.d3d_app_init_imgui(&app.base, &app.cbv_srv_uav_heap)
}

// C++: LitShapesApp::BuildRootSignature — two root CBVs plus the material buffer as a
// root SRV.
build_root_signature :: proc(app: ^Lit_Shapes_App) {
	// Root parameter can be a table, root descriptor or root constants.
	gfx_root_parameters: [Gfx_Root_Arg]d3d12.ROOT_PARAMETER

	// Perfomance TIP: Order from most frequent to least frequent.
	// C++: InitAsConstantBufferView(0) / (1); InitAsShaderResourceView(0).
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
	gfx_root_parameters[.MATERIAL_SRV] = {
		ParameterType = .SRV,
		Descriptor = {ShaderRegister = 0, RegisterSpace = 0},
		ShaderVisibility = .ALL,
	}

	// A root signature is an array of root parameters.
	root_sig_desc := d3d12.ROOT_SIGNATURE_DESC {
		NumParameters = len(Gfx_Root_Arg),
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

// C++: LitShapesApp::BuildShadersAndInputLayout — BasicLit.hlsl and the full ModelVertex
// layout (stride 44: POSITION 0, NORMAL 12, TEXCOORD 24, TANGENT 32).
build_shaders_and_input_layout :: proc(app: ^Lit_Shapes_App) {
	// C++: COMMA_DEBUG_ARGS — DXC_ARG_DEBUG, DXC_ARG_SKIP_OPTIMIZATIONS in debug builds.
	when ODIN_DEBUG {
		vs_args := [?]string{"-E", "VS", "-T", "vs_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
		ps_args := [?]string{"-E", "PS", "-T", "ps_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
	} else {
		vs_args := [?]string{"-E", "VS", "-T", "vs_6_6"}
		ps_args := [?]string{"-E", "PS", "-T", "ps_6_6"}
	}

	app.shaders["standardVS"] = common.compile_shader("Shaders/BasicLit.hlsl", vs_args[:])
	app.shaders["opaquePS"] = common.compile_shader("Shaders/BasicLit.hlsl", ps_args[:])

	app.input_layout = {
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .PER_VERTEX_DATA, 0},
		{"NORMAL", 0, .R32G32B32_FLOAT, 0, 12, .PER_VERTEX_DATA, 0},
		{"TEXCOORD", 0, .R32G32_FLOAT, 0, 24, .PER_VERTEX_DATA, 0},
		{"TANGENT", 0, .R32G32B32_FLOAT, 0, 32, .PER_VERTEX_DATA, 0},
	}
}

// C++: LitShapesApp::BuildPSOs.
build_psos :: proc(app: ^Lit_Shapes_App) {
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

// C++: LitShapesApp::BuildFrameResources.
build_frame_resources :: proc(app: ^Lit_Shapes_App) {
	pass_count :: 1
	for &fr in app.frame_resources {
		frame_resource_init(&fr, app.device, pass_count, u32(len(app.materials)))
	}
}

// C++: the AddMaterial lambda in LitShapesApp::BuildMaterials.
add_material :: proc(
	app: ^Lit_Shapes_App,
	name: string,
	diffuse: [4]f32,
	fresnel: [3]f32,
	roughness: f32,
) {
	mat := new(common.Material)
	mat.name = name
	mat.mat_index = app.next_mat_index
	mat.num_frames_dirty = common.NUM_FRAME_RESOURCES
	mat.diffuse_albedo = diffuse
	mat.fresnel_r0 = fresnel
	mat.roughness = roughness
	mat.mat_transform = d3d_math.MAT4_IDENTITY

	app.materials[name] = mat

	app.next_mat_index += 1
}

// C++: LitShapesApp::BuildMaterials.
build_materials :: proc(app: ^Lit_Shapes_App) {
	add_material(app, "forestGreen", FOREST_GREEN, {0.02, 0.02, 0.02}, 0.1)
	add_material(app, "steelBlue", STEEL_BLUE, {0.05, 0.05, 0.05}, 0.3)
	add_material(app, "lightGray", LIGHT_GRAY, {0.02, 0.02, 0.02}, 0.2)
	add_material(app, "skullMat", {1.0, 1.0, 1.0, 1.0}, {0.05, 0.05, 0.05}, 0.3)
}

// C++: LitShapesApp::AddRenderItem.
add_render_item :: proc(
	app: ^Lit_Shapes_App,
	layer: Render_Layer,
	world: d3d_math.Mat4,
	mat: ^common.Material,
	geo: ^common.Mesh_Geometry,
	draw_args: common.Submesh_Geometry,
) {
	ritem := new(Render_Item)
	ritem.world = world
	ritem.tex_transform = d3d_math.MAT4_IDENTITY
	ritem.mat = mat
	ritem.geo = geo
	ritem.primitive_type = .TRIANGLELIST
	ritem.index_count = draw_args.index_count
	ritem.start_index_location = draw_args.start_index_location
	ritem.base_vertex_location = draw_args.base_vertex_location

	append(&app.ritem_layer[layer], ritem)
	append(&app.all_ritems, ritem)
}

// C++: LitShapesApp::BuildRenderItems — the ch 7 shapes scene plus the skull on the box.
build_render_items :: proc(app: ^Lit_Shapes_App) {
	shape_geo := app.geometries["shapeGeo"]
	skull_geo := app.geometries["skullGeo"]

	world := d3d_math.scaling(2.0, 1.0, 2.0) * d3d_math.translation(0.0, 0.5, 0.0)
	add_render_item(app, .Opaque, world, app.materials["forestGreen"], shape_geo, shape_geo.draw_args["box"])

	add_render_item(app, .Opaque, d3d_math.MAT4_IDENTITY, app.materials["lightGray"], shape_geo, shape_geo.draw_args["grid"])

	world = d3d_math.scaling(0.4, 0.4, 0.4) * d3d_math.translation(0.0, 1.0, 0.0)
	add_render_item(app, .Opaque, world, app.materials["skullMat"], skull_geo, skull_geo.draw_args["skull"])

	for i in 0 ..< 5 {
		z := -10.0 + f32(i) * 5.0
		add_render_item(app, .Opaque, d3d_math.translation(-5.0, 1.5, z), app.materials["forestGreen"], shape_geo, shape_geo.draw_args["cylinder"])
		add_render_item(app, .Opaque, d3d_math.translation(+5.0, 1.5, z), app.materials["forestGreen"], shape_geo, shape_geo.draw_args["cylinder"])
		add_render_item(app, .Opaque, d3d_math.translation(-5.0, 3.5, z), app.materials["steelBlue"], shape_geo, shape_geo.draw_args["sphere"])
		add_render_item(app, .Opaque, d3d_math.translation(+5.0, 3.5, z), app.materials["steelBlue"], shape_geo, shape_geo.draw_args["sphere"])
	}
}
