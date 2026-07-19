// Port of `Demos/C8_LitWaves` (LitWavesApp.cpp/.h) — chapter 8's second demo: the ch 7
// hills-and-waves scene, lit. The land keeps its analytic normals (get_hills_normal,
// ported back in ch 7 and finally used) and the water's normals come out of the wave
// simulation each frame — watch the specular glints track the moving light. Materials
// replace the per-vertex colors: forestGreen land, lakeBlue water.
//
// The wave sim itself is in waves.odin (serial — see its header).
//
// Build & run FROM THE REPO ROOT (shader path + DXC DLLs are resolved relative to it):
//   odin run odin_port/C8_LitWaves -debug
package c8_litwaves

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

Lit_Waves_App :: struct {
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

	all_ritems:                [dynamic]^Render_Item,
	ritem_layer:               [Render_Layer][dynamic]^Render_Item,

	waves_ritem:               ^Render_Item,
	waves:                     Waves,
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

	next_mat_index:            i32, // C++: the matIndex captured by the AddMaterial lambda

	video_mem_poll_time:       f32,
	video_mem_info:            dxgi.QUERY_VIDEO_MEMORY_INFO,
}

main :: proc() {
	context = common.mem_track_init() // Odin-side leak detection (debug builds); see common/mem_track.odin

	app: Lit_Waves_App

	// C++ member initializers (LitWavesApp.h) — wireframe starts OFF in this demo.
	app.view = d3d_math.MAT4_IDENTITY
	app.proj = d3d_math.MAT4_IDENTITY
	app.theta = 1.5 * math.PI
	app.phi = math.PI / 2 - 0.1
	app.radius = 50.0
	app.draw_wireframe = false
	app.wave_scale = 1.0
	app.wave_speed = 8.0
	app.wave_damping = 0.1
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

	// C++: LitWavesApp::Initialize().
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

// C++: LitWavesApp::OnResize.
on_resize :: proc(base: ^common.D3D_App) {
	app := (^Lit_Waves_App)(base)

	common.on_resize(base) // C++: D3DApp::OnResize();

	// The window resized, so update the aspect ratio and recompute the projection matrix.
	app.proj = d3d_math.perspective_fov_lh(
		0.25 * math.PI,
		common.aspect_ratio(base),
		1.0,
		1000.0,
	)
}

// C++: LitWavesApp::Update.
update :: proc(base: ^common.D3D_App) {
	app := (^Lit_Waves_App)(base)

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
	update_waves(app)
}

// C++: LitWavesApp::OnKeyboardInput — empty in this demo.
on_keyboard_input :: proc(app: ^Lit_Waves_App) {
}

// C++: LitWavesApp::AnimateMaterials — empty in this demo.
animate_materials :: proc(app: ^Lit_Waves_App) {
}

// C++: LitWavesApp::UpdateCamera.
update_camera :: proc(app: ^Lit_Waves_App) {
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

// C++: LitWavesApp::UpdatePerObjectCB.
update_per_object_cb :: proc(app: ^Lit_Waves_App) {
	// Update per object constants once per frame so the data can be shared across
	// different render passes.
	for ri in app.all_ritems {
		ri.object_cb.world = linalg.transpose(ri.world)
		ri.object_cb.tex_transform = linalg.transpose(ri.tex_transform)
		ri.object_cb.material_index = u32(ri.mat.mat_index)

		// Need to hold handle until we submit work to GPU.
		ri.mem_handle_to_object_cb = common.allocate_constant(
			&app.linear_allocator,
			ri.object_cb,
		)
	}
}

// C++: LitWavesApp::UpdateMaterialBuffer.
update_material_buffer :: proc(app: ^Lit_Waves_App) {
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

// C++: LitWavesApp::UpdateMainPassCB — identical to LitShapes'.
update_main_pass_cb :: proc(app: ^Lit_Waves_App) {
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

// C++: LitWavesApp::UpdateWaves — the streamed vertices now carry the simulation's
// normals (that's what makes the water shade correctly).
update_waves :: proc(app: ^Lit_Waves_App) {
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
	verts := make([]common.Model_Vertex, app.waves.vertex_count, context.temp_allocator)
	for &v, i in verts {
		v.pos = app.waves.curr_solution[i]
		v.normal = app.waves.normals[i]

		// Not used in this demo.
		v.tex_c = {0.0, 0.0}
		v.tangent_u = {0.0, 0.0, 0.0}
	}
	common.copy_data_slice(curr_waves_vb, verts)

	// Set the dynamic VB of the wave renderitem to the current frame VB.
	// (A borrow — the C++ ComPtr assignment AddRefs; teardown nils this out, see main.)
	app.waves_ritem.geo.vertex_buffer_gpu = curr_waves_vb.upload_buffer
}

// C++: LitWavesApp::UpdateImgui — Options panel with the wave sliders.
update_imgui :: proc(app: ^Lit_Waves_App) {
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

// C++: LitWavesApp::Draw.
draw :: proc(base: ^common.D3D_App) {
	app := (^Lit_Waves_App)(base)

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

// C++: LitWavesApp::DrawRenderItems.
draw_render_items :: proc(app: ^Lit_Waves_App, ritems: []^Render_Item) {
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

// C++: LitWavesApp::OnMouseDown — ImGui gets first claim on the mouse.
on_mouse_down :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Lit_Waves_App)(base)
	io := im.GetIO()
	if !io.WantCaptureMouse {
		app.last_mouse_pos = {x, y}
		win.SetCapture(base.hwnd)
	}
}

// C++: LitWavesApp::OnMouseUp.
on_mouse_up :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	io := im.GetIO()
	if !io.WantCaptureMouse {
		win.ReleaseCapture()
	}
}

// C++: LitWavesApp::OnMouseMove — note the faster zoom (0.05/px) and wider radius clamp
// than the LitShapes demo.
on_mouse_move :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Lit_Waves_App)(base)
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

// C++: LitWavesApp::BuildCbvSrvUavDescriptorHeap.
build_cbv_srv_uav_descriptor_heap :: proc(app: ^Lit_Waves_App) {
	common.cbv_srv_uav_heap_init(&app.cbv_srv_uav_heap, app.device, CBV_SRV_UAV_HEAP_CAPACITY)
	common.d3d_app_init_imgui(&app.base, &app.cbv_srv_uav_heap)
}

// C++: LitWavesApp::BuildRootSignature — two root CBVs plus the material buffer as a
// root SRV (identical to C8_LitShapes').
build_root_signature :: proc(app: ^Lit_Waves_App) {
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

// C++: LitWavesApp::BuildShadersAndInputLayout — BasicLit.hlsl and the full ModelVertex
// layout (stride 44: POSITION 0, NORMAL 12, TEXCOORD 24, TANGENT 32).
build_shaders_and_input_layout :: proc(app: ^Lit_Waves_App) {
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

// C++: LitWavesApp::BuildPSOs.
build_psos :: proc(app: ^Lit_Waves_App) {
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

// C++: LitWavesApp::BuildFrameResources.
build_frame_resources :: proc(app: ^Lit_Waves_App) {
	pass_count :: 1
	for &fr in app.frame_resources {
		frame_resource_init(
			&fr,
			app.device,
			pass_count,
			u32(len(app.materials)),
			u32(app.waves.vertex_count),
		)
	}
}

// C++: the AddMaterial lambda in LitWavesApp::BuildMaterials.
add_material :: proc(
	app: ^Lit_Waves_App,
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

// C++: LitWavesApp::BuildMaterials — the same table as LitShapes plus lakeBlue; the C++
// builds all five even though this scene draws only two.
build_materials :: proc(app: ^Lit_Waves_App) {
	add_material(app, "forestGreen", FOREST_GREEN, {0.02, 0.02, 0.02}, 0.1)
	add_material(app, "steelBlue", STEEL_BLUE, {0.05, 0.05, 0.05}, 0.3)
	add_material(app, "lightGray", LIGHT_GRAY, {0.02, 0.02, 0.02}, 0.2)
	add_material(app, "skullMat", {1.0, 1.0, 1.0, 1.0}, {0.05, 0.05, 0.05}, 0.3)
	add_material(app, "lakeBlue", {0.2, 0.2, 0.8, 1.0}, {0.05, 0.05, 0.05}, 0.3)
}

// C++: LitWavesApp::AddRenderItem.
add_render_item :: proc(
	app: ^Lit_Waves_App,
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

// C++: LitWavesApp::BuildRenderItems — the water grid and the land grid, both at identity.
build_render_items :: proc(app: ^Lit_Waves_App) {
	water_geo := app.geometries["waterGeo"]
	add_render_item(app, .Opaque, d3d_math.MAT4_IDENTITY, app.materials["lakeBlue"], water_geo, water_geo.draw_args["grid"])
	app.waves_ritem = app.all_ritems[len(app.all_ritems) - 1]

	land_geo := app.geometries["landGeo"]
	add_render_item(app, .Opaque, d3d_math.MAT4_IDENTITY, app.materials["forestGreen"], land_geo, land_geo.draw_args["grid"])
}

// C++: LitWavesApp::BuildLandGeometry — a grid with the hills height function applied.
// The per-height vertex colors are gone; the analytic hills normal (finally used) plus
// the forestGreen material take over.
build_land_geometry :: proc(
	app: ^Lit_Waves_App,
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

		// Not used in this demo.
		v.tex_c = {0.0, 0.0}
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

// C++: LitWavesApp::BuildWaveGeometry — static 32-bit index buffer (128*128 > 0xffff
// vertices); the vertex buffer stays nil and is pointed at the current frame resource's
// dynamic VB every frame in update_waves.
build_wave_geometry :: proc(
	app: ^Lit_Waves_App,
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

	vb_byte_size := u32(app.waves.vertex_count * size_of(common.Model_Vertex))
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

	geo.vertex_byte_stride = size_of(common.Model_Vertex)
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

// C++: LitWavesApp::GetHillsHeight.
get_hills_height :: proc(x, z: f32) -> f32 {
	return 0.3 * (z * math.sin(0.1 * x) + x * math.cos(0.1 * z))
}

// C++: LitWavesApp::GetHillsNormal.
get_hills_normal :: proc(x, z: f32) -> [3]f32 {
	// n = (-df/dx, 1, -df/dz)
	n := [3]f32 {
		-0.03 * z * math.cos(0.1 * x) - 0.3 * math.cos(0.1 * z),
		1.0,
		-0.3 * math.sin(0.1 * x) + 0.03 * x * math.sin(0.1 * z),
	}
	return linalg.normalize(n)
}
