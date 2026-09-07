// Port of `Demos/C13_Blur` (BlurApp.cpp/.h) — GPU waves plus a separable compute blur
// scene split into opaque, alpha-tested, and transparent render layers. Water uses
// source-alpha blending, the wire-fence box uses the ALPHA_TEST shader permutation,
// and the shared pass constants drive distance fog.
//
// The wave sim is in gpu_waves.odin; blur_filter.odin performs the resize-aware post-process.
// chapter-9 texture-pipeline notes (DDS loader, bindless indices, sampler heap).
//
// Build & run FROM THE REPO ROOT (shader path + DXC DLLs are resolved relative to it):
//   odin run odin_port/C13_Blur -debug
package c13_blur

import "core:fmt"
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

// C++: constexpr UINT CBV_SRV_UAV_HEAP_CAPACITY = 16384;
CBV_SRV_UAV_HEAP_CAPACITY :: 16384

// C++: enum class RenderLayer.
Render_Layer :: enum {
	Opaque,
	Transparent,
	Alpha_Tested,
	Gpu_Waves,
	Debug,
	Sky,
}

// Lightweight structure stores parameters to draw a shape (same as C8_LitShapes).
Render_Item :: struct {
	world:                   d3d_math.Mat4,
	tex_transform:           d3d_math.Mat4,
	object_cb:               common.Per_Object_CB,
	mem_handle_to_object_cb: common.Graphics_Resource,
	mat:                     ^common.Material,
	geo:                     ^common.Mesh_Geometry,
	primitive_type:          d3d12.PRIMITIVE_TOPOLOGY,
	index_count:             u32,
	start_index_location:    u32,
	base_vertex_location:    i32,
}

Blur_App :: struct {
	using base:                common.D3D_App,
	cbv_srv_uav_heap:          common.Cbv_Srv_Uav_Heap,

	tex_lib:                   common.Texture_Lib,
	mat_lib:                   common.Material_Lib,

	frame_resources:           [common.NUM_FRAME_RESOURCES]Frame_Resource,
	curr_frame_resource:       ^Frame_Resource,
	curr_frame_resource_index: int,

	root_signature:            ^d3d12.IRootSignature,
	compute_root_signature:    ^d3d12.IRootSignature,

	geometries:                map[string]^common.Mesh_Geometry,
	shaders:                   map[string]^dxc.IBlob,
	psos:                      map[string]^d3d12.IPipelineState,

	input_layout:              [4]d3d12.INPUT_ELEMENT_DESC,

	all_ritems:                [dynamic]^Render_Item,
	ritem_layer:               [Render_Layer][dynamic]^Render_Item,

	waves:                     Gpu_Waves,
	blur_filter:               Blur_Filter,
	t_base:                    f32, // C++: function-local static in UpdateWaves

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
	wave_scale:                f32,
	wave_speed:                f32,
	wave_damping:              f32,
	blur_count:                i32,
	blur_sigma:                f32,

	fog_color:                 [4]f32,
	fog_enabled:               bool,
	fog_start:                 f32,
	fog_end:                   f32,

	video_mem_poll_time:       f32,
	video_mem_info:            dxgi.QUERY_VIDEO_MEMORY_INFO,
}

main :: proc() {
	context = common.mem_track_init() // Odin-side leak detection (debug builds); see common/mem_track.odin

	app: Blur_App

	// C++ member initializers (BlurApp.h).
	app.view = d3d_math.MAT4_IDENTITY
	app.proj = d3d_math.MAT4_IDENTITY
	app.theta = 1.5 * math.PI
	app.phi = math.PI / 2 - 0.1
	app.radius = 50.0
	app.draw_wireframe = false
	app.wave_scale = 1.0
	app.wave_speed = 8.0
	app.wave_damping = 0.1
	app.blur_count = 1
	app.blur_sigma = 4.0
	app.fog_color = {0.6, 0.6, 0.6, 1.0}
	app.fog_enabled = true
	app.fog_start = 20.0
	app.fog_end = 160.0
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

	// C++: BlurApp::Initialize().
	common.d3d_app_init(&app.base)

	// We will upload on the direct queue for the book samples, but
	// copy queue would be better for real game.
	upload_batch: common.Resource_Upload_Batch
	common.upload_batch_begin(&upload_batch, app.device)
	gpu_waves_init(
		&app.waves, &upload_batch, 256, 256, 0.25, 0.016,
		app.wave_speed, app.wave_damping,
	)
	blur_filter_init(
		&app.blur_filter, app.device, u32(app.client_width), u32(app.client_height),
		app.back_buffer_format,
	)

	// C++: LoadTextures() — TextureLib::Init.
	common.texture_lib_init(&app.tex_lib, &upload_batch)

	land_geo := build_land_geometry(&app, &upload_batch)
	app.geometries[land_geo.name] = land_geo

	wave_geo := build_wave_geometry(&app, &upload_batch)
	app.geometries[wave_geo.name] = wave_geo

	shape_geo := build_shape_geometry(&app, &upload_batch)
	app.geometries[shape_geo.name] = shape_geo

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
	if app.compute_root_signature != nil {app.compute_root_signature->Release()}
	for &fr in app.frame_resources {frame_resource_destroy(&fr)}
	for ritem in app.all_ritems {free(ritem)}
	delete(app.all_ritems)
	for &layer in app.ritem_layer {delete(layer)}
	common.material_lib_destroy(&app.mat_lib)
	common.texture_lib_destroy(&app.tex_lib)
	for _, geo in app.geometries {common.mesh_geometry_destroy(geo);free(geo)}
	delete(app.geometries)
	gpu_waves_destroy(&app.waves)
	blur_filter_destroy(&app.blur_filter)
	common.cbv_srv_uav_heap_destroy(&app.cbv_srv_uav_heap)
	common.d3d_app_shutdown(&app.base)
	common.mem_track_report() // before os.exit — os.exit skips defers
	os.exit(code)
}

// C++: BlurApp::OnResize.
on_resize :: proc(base: ^common.D3D_App) {
	app := (^Blur_App)(base)

	common.on_resize(base) // C++: D3DApp::OnResize();
	blur_filter_on_resize(&app.blur_filter, u32(app.client_width), u32(app.client_height))

	// The window resized, so update the aspect ratio and recompute the projection matrix.
	app.proj = d3d_math.perspective_fov_lh(
		0.25 * math.PI,
		common.aspect_ratio(base),
		1.0,
		1000.0,
	)
}

// C++: BlurApp::Update.
update :: proc(base: ^common.D3D_App) {
	app := (^Blur_App)(base)

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

// C++: BlurApp::OnKeyboardInput — empty in this demo.
on_keyboard_input :: proc(app: ^Blur_App) {
}

// C++: BlurApp::AnimateMaterials — scroll the water material texture coordinates.
// (Row 3 of the row-major MatTransform is the translation row, [3][0]=tu, [3][1]=tv —
// the C++'s MatTransform(3, 0)/(3, 1).)
animate_materials :: proc(app: ^Blur_App) {
	water_mat := common.material_lib_get(&app.mat_lib, "water")

	dt := common.game_timer_delta_time(&app.timer)
	tu := water_mat.mat_transform[3, 0] + 0.1 * dt
	tv := water_mat.mat_transform[3, 1] + 0.02 * dt

	if tu >= 1.0 {
		tu -= 1.0
	}
	if tv >= 1.0 {
		tv -= 1.0
	}

	water_mat.mat_transform[3, 0] = tu
	water_mat.mat_transform[3, 1] = tv

	// Material has changed, so need to update cbuffer.
	water_mat.num_frames_dirty = common.NUM_FRAME_RESOURCES
}

// C++: BlurApp::UpdateCamera.
update_camera :: proc(app: ^Blur_App) {
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

// C++: BlurApp::UpdatePerObjectCB.
update_per_object_cb :: proc(app: ^Blur_App) {
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

// C++: BlurApp::UpdateMaterialBuffer — the upload now carries the texture transform
// and the bindless texture indices alongside the shading constants.
update_material_buffer :: proc(app: ^Blur_App) {
	curr_material_buffer := &app.curr_frame_resource.material_buffer
	for _, mat in app.mat_lib.materials {
		// Only update the buffer data if the data has changed.  If the buffer
		// data changes, it needs to be updated for each FrameResource.
		if mat.num_frames_dirty > 0 {
			mat_data: common.Material_Data
			mat_data.diffuse_albedo = mat.diffuse_albedo
			mat_data.fresnel_r0 = mat.fresnel_r0
			mat_data.roughness = mat.roughness
			mat_data.mat_transform = linalg.transpose(mat.mat_transform)
			mat_data.diffuse_map_index = u32(mat.albedo_bindless_index)
			mat_data.normal_map_index = u32(mat.normal_bindless_index)
			mat_data.gloss_height_ao_map_index = u32(mat.gloss_height_ao_bindless_index)

			common.copy_data(curr_material_buffer, int(mat.mat_index), mat_data)

			// Next FrameResource need to be updated too.
			mat.num_frames_dirty -= 1
		}
	}
}

// C++: BlurApp::UpdateMainPassCB — camera, lighting, fog and wave parameters.
update_main_pass_cb :: proc(app: ^Blur_App) {
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
	cb.fog_color = app.fog_color
	cb.fog_start = app.fog_start
	cb.fog_range = app.fog_end - app.fog_start
	cb.fog_enabled = app.fog_enabled ? 1 : 0

	cb.num_dir_lights = 3
	cb.num_point_lights = 0
	cb.num_spot_lights = 0

	cb.lights[0].direction = app.rotated_light_directions[0]
	cb.lights[0].strength = {0.8, 0.75, 0.7}
	cb.lights[1].direction = app.rotated_light_directions[1]
	cb.lights[1].strength = {0.3, 0.3, 0.3}
	cb.lights[2].direction = app.rotated_light_directions[2]
	cb.lights[2].strength = {0.2, 0.2, 0.2}

	common.copy_data(&app.curr_frame_resource.pass_cb, 0, app.main_pass_cb)
}

// C++: BlurApp::UpdateWavesGPU.
update_waves_gpu :: proc(app: ^Blur_App, pass_cb: ^d3d12.IResource) {
	if common.game_timer_total_time(&app.timer) - app.t_base >= 0.25 {
		app.t_base += 0.25
		i := u32(4 + rand.int_max(int(app.waves.num_rows) - 5 - 4 + 1))
		j := u32(4 + rand.int_max(int(app.waves.num_cols) - 5 - 4 + 1))
		r := app.wave_scale * rand.float32_range(1.0, 2.0)
		gpu_waves_disturb(
			&app.waves, app.command_list, app.compute_root_signature, pass_cb,
			app.psos["wavesDisturb"], &app.linear_allocator, i, j, r,
		)
	}

	gpu_waves_update(
		&app.waves, common.game_timer_delta_time(&app.timer), app.command_list,
		app.compute_root_signature, pass_cb, app.psos["wavesUpdate"],
		&app.linear_allocator,
	)
	gpu_waves_prepare_render(&app.waves, app.command_list)
	for ri in app.ritem_layer[.Gpu_Waves] {
		ri.object_cb.misc_uint4[0] = gpu_waves_displacement_map_srv_index(&app.waves)
		ri.mem_handle_to_object_cb = common.allocate_constant(
			&app.linear_allocator, ri.object_cb,
		)
	}
}

// C++: BlurApp::UpdateImgui — Options panel with wave and blur controls.
update_imgui :: proc(app: ^Blur_App) {
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
	im.Checkbox("FogEnabled", &app.fog_enabled)
	im.SliderFloat("FogStart", &app.fog_start, 10.0, 100.0)
	im.SliderFloat("FogEnd", &app.fog_end, 20.0, 200.0)
	if app.fog_start >= app.fog_end {
		app.fog_start = 10.0
	}
	im.SliderFloat("WaveScale", &app.wave_scale, 0.25, 4.0)
	im.SliderFloat("WaveSpeed", &app.wave_speed, 2.0, 16.0)
	im.SliderFloat("WaveDamping", &app.wave_damping, 0.0, 3.0)
	im.SliderFloat("BlurSigma", &app.blur_sigma, 0.5, 7.0)
	im.SliderInt("BlurCount", &app.blur_count, 1, 4)

	gpu_waves_set_constants(&app.waves, app.wave_speed, app.wave_damping)

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

// C++: BlurApp::Draw.
draw :: proc(base: ^common.D3D_App) {
	app := (^Blur_App)(base)

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

	descriptor_heaps := [?]^d3d12.IDescriptorHeap{app.cbv_srv_uav_heap.heap, app.sampler_heap.heap}
	base.command_list->SetDescriptorHeaps(len(descriptor_heaps), &descriptor_heaps[0])
	pass_cb := app.curr_frame_resource.pass_cb.upload_buffer
	update_waves_gpu(app, pass_cb)

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

	// Clear to the fog color so distant geometry blends into the background.
	clear_color := [4]f32{0.0, 0.0, 0.2, 0.0}
	if app.fog_enabled {
		clear_color = app.fog_color
	}
	rtv := common.current_back_buffer_view(base)
	dsv := common.depth_stencil_view(base)
	base.command_list->ClearRenderTargetView(rtv, &clear_color, 0, nil)
	base.command_list->ClearDepthStencilView(dsv, {.DEPTH, .STENCIL}, 1.0, 0, 0, nil)

	// Specify the buffers we are going to render to.
	base.command_list->OMSetRenderTargets(1, &rtv, true, &dsv)

	// Pass constants: a root descriptor — no CBV/heap involved.
	base.command_list->SetGraphicsRootConstantBufferView(
		u32(Gfx_Root_Arg.PASS_CBV),
		pass_cb->GetGPUVirtualAddress(),
	)

	base.command_list->SetPipelineState(
		app.draw_wireframe ? app.psos["opaque_wireframe"] : app.psos["opaque"],
	)
	draw_render_items(app, app.ritem_layer[.Opaque][:])

	base.command_list->SetPipelineState(
		app.draw_wireframe ? app.psos["opaque_wireframe"] : app.psos["alphaTested"],
	)
	draw_render_items(app, app.ritem_layer[.Alpha_Tested][:])

	base.command_list->SetPipelineState(
		app.draw_wireframe ? app.psos["opaque_wireframe"] : app.psos["transparent"],
	)
	draw_render_items(app, app.ritem_layer[.Transparent][:])

	base.command_list->SetPipelineState(
		app.draw_wireframe ? app.psos["waves_wireframe"] : app.psos["waves_transparent"],
	)
	draw_render_items(app, app.ritem_layer[.Gpu_Waves][:])

	back_buffer := common.current_back_buffer(base)
	blur_filter_execute(
		&app.blur_filter,
		base.command_list,
		app.compute_root_signature,
		pass_cb,
		app.psos["horzBlur"],
		app.psos["vertBlur"],
		back_buffer,
		app.blur_count,
		app.blur_sigma,
		&app.linear_allocator,
	)
	blur_output := blur_filter_output(&app.blur_filter)
	to_copy := [?]d3d12.RESOURCE_BARRIER {
		common.transition_barrier(back_buffer, {.COPY_SOURCE}, {.COPY_DEST}),
		common.transition_barrier(blur_output, {.NON_PIXEL_SHADER_RESOURCE}, {.COPY_SOURCE}),
	}
	base.command_list->ResourceBarrier(len(to_copy), &to_copy[0])
	base.command_list->CopyResource(back_buffer, blur_output)
	from_copy := [?]d3d12.RESOURCE_BARRIER {
		common.transition_barrier(back_buffer, {.COPY_DEST}, {.RENDER_TARGET}),
		common.transition_barrier(blur_output, {.COPY_SOURCE}, {.NON_PIXEL_SHADER_RESOURCE}),
	}
	base.command_list->ResourceBarrier(len(from_copy), &from_copy[0])

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

// C++: BlurApp::DrawRenderItems.
draw_render_items :: proc(app: ^Blur_App, ritems: []^Render_Item) {
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

// C++: BlurApp::OnMouseDown — ImGui gets first claim on the mouse.
on_mouse_down :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Blur_App)(base)
	io := im.GetIO()
	if !io.WantCaptureMouse {
		app.last_mouse_pos = {x, y}
		win.SetCapture(base.hwnd)
	}
}

// C++: BlurApp::OnMouseUp.
on_mouse_up :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	io := im.GetIO()
	if !io.WantCaptureMouse {
		win.ReleaseCapture()
	}
}

// C++: BlurApp::OnMouseMove — note the faster zoom (0.05/px) and wider radius clamp
// than the LitShapes demo.
on_mouse_move :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Blur_App)(base)
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

// C++: BlurApp::BuildCbvSrvUavDescriptorHeap — after ImGui claims its slot, every
// texture gets a bindless index and an SRV at that index (see C9_Crate).
build_cbv_srv_uav_descriptor_heap :: proc(app: ^Blur_App) {
	common.cbv_srv_uav_heap_init(&app.cbv_srv_uav_heap, app.device, CBV_SRV_UAV_HEAP_CAPACITY)
	common.d3d_app_init_imgui(&app.base, &app.cbv_srv_uav_heap)

	for _, tex in app.tex_lib.textures {
		tex.bindless_index = i32(common.next_free_index(&app.cbv_srv_uav_heap))

		h_descriptor := common.cpu_handle(&app.cbv_srv_uav_heap, u32(tex.bindless_index))
		desc: d3d12.RESOURCE_DESC
		tex.resource->GetDesc(&desc)
		if tex.is_cube_map {
			common.create_srv_cube(app.device, tex.resource, desc.Format, desc.MipLevels, h_descriptor)
		} else {
			common.create_srv_2d(app.device, tex.resource, desc.Format, desc.MipLevels, h_descriptor)
		}
	}
	gpu_waves_build_descriptors(&app.waves, app.device, &app.cbv_srv_uav_heap)
	blur_filter_build_descriptors(&app.blur_filter, &app.cbv_srv_uav_heap)
}

// C++: BlurApp::BuildRootSignature — two root CBVs plus the material buffer as a
// root SRV (identical to C8_LitShapes').
build_root_signature :: proc(app: ^Blur_App) {
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

	// A root signature is an array of root parameters. The two "directly indexed" flags
	// enable SM 6.6 ResourceDescriptorHeap[]/SamplerDescriptorHeap[] in the shaders.
	root_sig_desc := d3d12.ROOT_SIGNATURE_DESC {
		NumParameters = len(Gfx_Root_Arg),
		pParameters   = &gfx_root_parameters[.OBJECT_CBV],
		Flags         = {
			.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
			.CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED,
			.SAMPLER_HEAP_DIRECTLY_INDEXED,
		},
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

	compute_root_parameters: [Compute_Root_Arg]d3d12.ROOT_PARAMETER
	compute_root_parameters[.DISPATCH_CBV] = {
		ParameterType = .CBV,
		Descriptor = {ShaderRegister = 0},
		ShaderVisibility = .ALL,
	}
	compute_root_parameters[.PASS_CBV] = {
		ParameterType = .CBV,
		Descriptor = {ShaderRegister = 1},
		ShaderVisibility = .ALL,
	}
	compute_root_parameters[.PASS_EXTRA_CBV] = {
		ParameterType = .CBV,
		Descriptor = {ShaderRegister = 2},
		ShaderVisibility = .ALL,
	}
	compute_desc := d3d12.ROOT_SIGNATURE_DESC {
		NumParameters = len(Compute_Root_Arg),
		pParameters = &compute_root_parameters[.DISPATCH_CBV],
		Flags = {.CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED, .SAMPLER_HEAP_DIRECTLY_INDEXED},
	}
	compute_blob: ^d3d12.IBlob
	compute_error_blob: ^d3d12.IBlob
	hr = d3d12.SerializeRootSignature(
		&compute_desc, ._1_0, &compute_blob, &compute_error_blob,
	)
	if compute_error_blob != nil {
		common.report_error(string(cstring(compute_error_blob->GetBufferPointer())))
		compute_error_blob->Release()
	}
	common.hr_panic(hr, "D3D12SerializeRootSignature(compute)")
	defer compute_blob->Release()
	common.hr_panic(
		app.device->CreateRootSignature(
			0, compute_blob->GetBufferPointer(), compute_blob->GetBufferSize(),
			d3d12.IRootSignature_UUID, common.ptr(&app.compute_root_signature),
		),
		"CreateRootSignature(compute)",
	)
}

// C++: BlurApp::BuildShadersAndInputLayout — render permutations plus wave and blur compute shaders.
build_shaders_and_input_layout :: proc(app: ^Blur_App) {
	// C++: COMMA_DEBUG_ARGS — DXC_ARG_DEBUG, DXC_ARG_SKIP_OPTIMIZATIONS in debug builds.
	when ODIN_DEBUG {
		vs_args := [?]string{"-E", "VS", "-T", "vs_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
		vs_waves_args := [?]string{"-E", "VS", "-T", "vs_6_6", "-D", "WAVES_VS=1", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
		ps_args := [?]string{"-E", "PS", "-T", "ps_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
		ps_alpha_tested_args := [?]string{"-E", "PS", "-T", "ps_6_6", "-D", "ALPHA_TEST=1", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
		cs_update_args := [?]string{"-E", "UpdateWavesCS", "-T", "cs_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
		cs_disturb_args := [?]string{"-E", "DisturbWavesCS", "-T", "cs_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
		cs_horz_blur_args := [?]string{"-E", "HorzBlurCS", "-T", "cs_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
		cs_vert_blur_args := [?]string{"-E", "VertBlurCS", "-T", "cs_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
	} else {
		vs_args := [?]string{"-E", "VS", "-T", "vs_6_6"}
		vs_waves_args := [?]string{"-E", "VS", "-T", "vs_6_6", "-D", "WAVES_VS=1"}
		ps_args := [?]string{"-E", "PS", "-T", "ps_6_6"}
		ps_alpha_tested_args := [?]string{"-E", "PS", "-T", "ps_6_6", "-D", "ALPHA_TEST=1"}
		cs_update_args := [?]string{"-E", "UpdateWavesCS", "-T", "cs_6_6"}
		cs_disturb_args := [?]string{"-E", "DisturbWavesCS", "-T", "cs_6_6"}
		cs_horz_blur_args := [?]string{"-E", "HorzBlurCS", "-T", "cs_6_6"}
		cs_vert_blur_args := [?]string{"-E", "VertBlurCS", "-T", "cs_6_6"}
	}

	app.shaders["standardVS"] = common.compile_shader("Shaders/BasicBlend.hlsl", vs_args[:])
	app.shaders["opaquePS"] = common.compile_shader("Shaders/BasicBlend.hlsl", ps_args[:])
	app.shaders["alphaTestedPS"] = common.compile_shader(
		"Shaders/BasicBlend.hlsl",
		ps_alpha_tested_args[:],
	)
	app.shaders["wavesVS"] = common.compile_shader("Shaders/BasicBlend.hlsl", vs_waves_args[:])
	app.shaders["wavesUpdateCS"] = common.compile_shader("Shaders/WaveSim.hlsl", cs_update_args[:])
	app.shaders["wavesDisturbCS"] = common.compile_shader("Shaders/WaveSim.hlsl", cs_disturb_args[:])
	app.shaders["horzBlurCS"] = common.compile_shader("Shaders/Blur.hlsl", cs_horz_blur_args[:])
	app.shaders["vertBlurCS"] = common.compile_shader("Shaders/Blur.hlsl", cs_vert_blur_args[:])

	app.input_layout = {
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .PER_VERTEX_DATA, 0},
		{"NORMAL", 0, .R32G32B32_FLOAT, 0, 12, .PER_VERTEX_DATA, 0},
		{"TEXCOORD", 0, .R32G32_FLOAT, 0, 24, .PER_VERTEX_DATA, 0},
		{"TANGENT", 0, .R32G32B32_FLOAT, 0, 32, .PER_VERTEX_DATA, 0},
	}
}

// C++: BlurApp::BuildPSOs.
build_psos :: proc(app: ^Blur_App) {
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

	// PSO for transparent objects: standard source-alpha blending.
	transparent_pso_desc := base_pso_desc
	transparent_pso_desc.BlendState.RenderTarget[0] = {
		BlendEnable           = true,
		LogicOpEnable         = false,
		SrcBlend              = .SRC_ALPHA,
		DestBlend             = .INV_SRC_ALPHA,
		BlendOp               = .ADD,
		SrcBlendAlpha         = .ONE,
		DestBlendAlpha        = .ZERO,
		BlendOpAlpha          = .ADD,
		LogicOp               = .NOOP,
		RenderTargetWriteMask = 0x0F,
	}

	transparent: ^d3d12.IPipelineState
	common.hr_panic(
		app.device->CreateGraphicsPipelineState(
			&transparent_pso_desc,
			d3d12.IPipelineState_UUID,
			common.ptr(&transparent),
		),
		"CreateGraphicsPipelineState(transparent)",
	)
	app.psos["transparent"] = transparent

	// PSO for alpha-tested objects: use clip() and render both sides of the fence.
	alpha_tested_pso_desc := base_pso_desc
	alpha_tested_pso_desc.PS = common.byte_code_from_blob(app.shaders["alphaTestedPS"])
	alpha_tested_pso_desc.RasterizerState.CullMode = .NONE

	alpha_tested: ^d3d12.IPipelineState
	common.hr_panic(
		app.device->CreateGraphicsPipelineState(
			&alpha_tested_pso_desc,
			d3d12.IPipelineState_UUID,
			common.ptr(&alpha_tested),
		),
		"CreateGraphicsPipelineState(alphaTested)",
	)
	app.psos["alphaTested"] = alpha_tested

	waves_render_desc := transparent_pso_desc
	waves_render_desc.VS = common.byte_code_from_blob(app.shaders["wavesVS"])
	waves_transparent: ^d3d12.IPipelineState
	common.hr_panic(
		app.device->CreateGraphicsPipelineState(
			&waves_render_desc, d3d12.IPipelineState_UUID,
			common.ptr(&waves_transparent),
		),
		"CreateGraphicsPipelineState(waves_transparent)",
	)
	app.psos["waves_transparent"] = waves_transparent

	waves_wire_desc := base_pso_desc
	waves_wire_desc.VS = common.byte_code_from_blob(app.shaders["wavesVS"])
	waves_wire_desc.RasterizerState.FillMode = .WIREFRAME
	waves_wireframe: ^d3d12.IPipelineState
	common.hr_panic(
		app.device->CreateGraphicsPipelineState(
			&waves_wire_desc, d3d12.IPipelineState_UUID,
			common.ptr(&waves_wireframe),
		),
		"CreateGraphicsPipelineState(waves_wireframe)",
	)
	app.psos["waves_wireframe"] = waves_wireframe

	compute_shader_names := [?]string{
		"wavesDisturbCS", "wavesUpdateCS", "horzBlurCS", "vertBlurCS",
	}
	compute_pso_names := [?]string{
		"wavesDisturb", "wavesUpdate", "horzBlur", "vertBlur",
	}
	for shader_name, i in compute_shader_names {
		pso_name := compute_pso_names[i]
		desc := d3d12.COMPUTE_PIPELINE_STATE_DESC {
			pRootSignature = app.compute_root_signature,
			CS = common.byte_code_from_blob(app.shaders[shader_name]),
		}
		pso: ^d3d12.IPipelineState
		common.hr_panic(
			app.device->CreateComputePipelineState(
				&desc, d3d12.IPipelineState_UUID, common.ptr(&pso),
			),
			fmt.tprintf("CreateComputePipelineState(%s)", pso_name),
		)
		app.psos[pso_name] = pso
	}
}

// C++: BlurApp::BuildFrameResources.
build_frame_resources :: proc(app: ^Blur_App) {
	pass_count :: 1
	for &fr in app.frame_resources {
		frame_resource_init(
			&fr,
			app.device,
			pass_count,
			common.material_count(&app.mat_lib),
		)
	}
}

// C++: BlurApp::BuildMaterials — MaterialLib::GetLib().Init(...).
build_materials :: proc(app: ^Blur_App) {
	common.material_lib_init(&app.mat_lib, &app.tex_lib)
}

// C++: BlurApp::AddRenderItem — record world/texture transforms and the material.
add_render_item :: proc(
	app: ^Blur_App,
	layer: Render_Layer,
	world: d3d_math.Mat4,
	tex_transform: d3d_math.Mat4,
	mat: ^common.Material,
	geo: ^common.Mesh_Geometry,
	draw_args: common.Submesh_Geometry,
) {
	ritem := new(Render_Item)
	ritem.world = world
	ritem.tex_transform = tex_transform
	ritem.mat = mat
	ritem.geo = geo
	ritem.primitive_type = .TRIANGLELIST
	ritem.index_count = draw_args.index_count
	ritem.start_index_location = draw_args.start_index_location
	ritem.base_vertex_location = draw_args.base_vertex_location

	append(&app.ritem_layer[layer], ritem)
	append(&app.all_ritems, ritem)
}

// C++: BlurApp::BuildRenderItems — transparent tiled water (5x5), opaque grass
// (8x8), and an alpha-tested wire-fence box.
build_render_items :: proc(app: ^Blur_App) {
	water_geo := app.geometries["waterGeo"]
	add_render_item(
		app,
		.Gpu_Waves,
		d3d_math.MAT4_IDENTITY,
		d3d_math.scaling(5.0, 5.0, 1.0),
		common.material_lib_get(&app.mat_lib, "water"),
		water_geo,
		water_geo.draw_args["grid"],
	)
	waves_item := app.all_ritems[len(app.all_ritems) - 1]
	waves_item.object_cb.misc_uint4[1] = app.waves.num_cols
	waves_item.object_cb.misc_uint4[2] = app.waves.num_rows
	waves_item.object_cb.misc_float4[0] = app.waves.spatial_step

	land_geo := app.geometries["landGeo"]
	add_render_item(
		app,
		.Opaque,
		d3d_math.MAT4_IDENTITY,
		d3d_math.scaling(8.0, 8.0, 1.0),
		common.material_lib_get(&app.mat_lib, "grass"),
		land_geo,
		land_geo.draw_args["grid"],
	)

	shape_geo := app.geometries["shapeGeo"]
	world := d3d_math.scaling(8.0, 8.0, 8.0) * d3d_math.translation(3.0, 2.0, -9.0)
	add_render_item(
		app,
		.Alpha_Tested,
		world,
		d3d_math.MAT4_IDENTITY,
		common.material_lib_get(&app.mat_lib, "fence"),
		shape_geo,
		shape_geo.draw_args["box"],
	)
}

// C++: BlurApp::BuildLandGeometry — a grid with the hills height function applied;
// the grid's generated UVs come along now (the grass texture needs them).
build_land_geometry :: proc(
	app: ^Blur_App,
	upload_batch: ^common.Resource_Upload_Batch,
) -> ^common.Mesh_Geometry {
	grid := common.create_grid(160.0, 160.0, 50, 50)
	defer common.mesh_gen_data_destroy(&grid)

	//
	// Extract the vertex elements we are interested and apply the height function to
	// each vertex.
	//

	vertices := make([]common.Model_Vertex, len(grid.vertices))
	defer delete(vertices)
	for &v, i in vertices {
		p := grid.vertices[i].position
		v.pos = p
		v.pos.y = get_hills_height(p.x, p.z)

		v.normal = get_hills_normal(p.x, p.z)

		v.tex_c = grid.vertices[i].tex_c

		// Not used in this demo.
		v.tangent_u = {0.0, 0.0, 0.0}
	}

	indices := common.get_indices16(&grid)
	defer delete(indices)

	vb_byte_size := u32(len(vertices) * size_of(common.Model_Vertex))
	ib_byte_size := u32(len(indices) * size_of(u16))

	geo := new(common.Mesh_Geometry)
	geo.name = "landGeo"

	geo.vertex_buffer_cpu = slice.clone(slice.to_bytes(vertices))
	geo.index_buffer_cpu = slice.clone(slice.to_bytes(indices))

	common.create_static_buffer(
		upload_batch,
		raw_data(vertices),
		len(vertices),
		size_of(common.Model_Vertex),
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

	geo.vertex_byte_stride = size_of(common.Model_Vertex)
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

// C++: BlurApp::BuildWaveGeometry — a static 256x256 water grid displaced in the vertex
// shader from the compute simulation's current height texture.
build_wave_geometry :: proc(
	app: ^Blur_App,
	upload_batch: ^common.Resource_Upload_Batch,
) -> ^common.Mesh_Geometry {
	grid := common.create_grid(128.0, 128.0, app.waves.num_rows, app.waves.num_cols)
	defer common.mesh_gen_data_destroy(&grid)
	vertices := make([]common.Model_Vertex, len(grid.vertices))
	defer delete(vertices)
	for &vertex, i in vertices {
		vertex.pos = grid.vertices[i].position
		vertex.normal = grid.vertices[i].normal
		vertex.tex_c = grid.vertices[i].tex_c
		vertex.tangent_u = grid.vertices[i].tangent_u
	}

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

	vb_byte_size := u32(app.waves.vertex_count * size_of(common.Model_Vertex))
	ib_byte_size := u32(len(indices) * size_of(u32))

	geo := new(common.Mesh_Geometry)
	geo.name = "waterGeo"

	geo.vertex_buffer_cpu = slice.clone(slice.to_bytes(vertices))
	geo.index_buffer_cpu = slice.clone(slice.to_bytes(indices))

	common.create_static_buffer(
		upload_batch,
		raw_data(vertices),
		len(vertices),
		size_of(common.Model_Vertex),
		{.VERTEX_AND_CONSTANT_BUFFER},
		&geo.vertex_buffer_gpu,
	)

	common.create_static_buffer(
		upload_batch,
		raw_data(indices),
		len(indices),
		size_of(u32),
		{.INDEX_BUFFER},
		&geo.index_buffer_gpu,
	)

	geo.vertex_byte_stride = size_of(common.Model_Vertex)
	geo.vertex_buffer_byte_size = vb_byte_size
	geo.index_format = .R32_UINT
	geo.index_buffer_byte_size = ib_byte_size

	geo.draw_args["grid"] = common.Submesh_Geometry {
		index_count          = u32(len(indices)),
		start_index_location = 0,
		base_vertex_location = 0,
		vertex_count = u32(len(vertices)),
	}

	return geo
}

// C++: d3dUtil::BuildShapeGeometry — reduced to the wire-fence box used by this demo.
build_shape_geometry :: proc(
	app: ^Blur_App,
	upload_batch: ^common.Resource_Upload_Batch,
) -> ^common.Mesh_Geometry {
	box := common.create_box(1.0, 1.0, 1.0, 3)
	defer common.mesh_gen_data_destroy(&box)

	composite_mesh: common.Mesh_Gen_Data
	defer common.mesh_gen_data_destroy(&composite_mesh)
	box_submesh := common.append_submesh(&composite_mesh, &box)

	// Extract the vertex elements we are interested into our vertex buffer.
	vertices := make([]common.Model_Vertex, len(composite_mesh.vertices))
	defer delete(vertices)
	for &v, i in vertices {
		v.pos = composite_mesh.vertices[i].position
		v.normal = composite_mesh.vertices[i].normal
		v.tex_c = composite_mesh.vertices[i].tex_c
		v.tangent_u = composite_mesh.vertices[i].tangent_u
	}

	indices := common.get_indices16(&composite_mesh)
	defer delete(indices)

	vb_byte_size := u32(len(vertices) * size_of(common.Model_Vertex))
	ib_byte_size := u32(len(indices) * size_of(u16))

	geo := new(common.Mesh_Geometry)
	geo.name = "shapeGeo"

	geo.vertex_buffer_cpu = slice.clone(slice.to_bytes(vertices))
	geo.index_buffer_cpu = slice.clone(slice.to_bytes(indices))

	common.create_static_buffer(
		upload_batch,
		raw_data(vertices),
		len(vertices),
		size_of(common.Model_Vertex),
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

	geo.vertex_byte_stride = size_of(common.Model_Vertex)
	geo.vertex_buffer_byte_size = vb_byte_size
	geo.index_format = .R16_UINT
	geo.index_buffer_byte_size = ib_byte_size

	geo.draw_args["box"] = box_submesh

	return geo
}

// C++: BlurApp::GetHillsHeight.
get_hills_height :: proc(x, z: f32) -> f32 {
	return 0.3 * (z * math.sin(0.1 * x) + x * math.cos(0.1 * z))
}

// C++: BlurApp::GetHillsNormal.
get_hills_normal :: proc(x, z: f32) -> [3]f32 {
	// n = (-df/dx, 1, -df/dz)
	n := [3]f32 {
		-0.03 * z * math.cos(0.1 * x) - 0.3 * math.cos(0.1 * z),
		1.0,
		-0.3 * math.sin(0.1 * x) + 0.03 * x * math.sin(0.1 * z),
	}
	return linalg.normalize(n)
}
