// Port of `Demos/C6_BoxGrid` (BoxGridApp.cpp/.h) — chapter 6's second demo: the same
// colored box drawn 9 times in a 3x3 grid on the xz-plane. What it adds over C6_Box:
// ONE upload buffer holds an ARRAY of per-object constants (BOX_COUNT elements, each
// 256-byte aligned), with one CBV per element at `i * objCBByteSize` — and the draw loop
// re-points the object descriptor table between DrawIndexedInstanced calls while the pass
// table stays bound once.
//
// Build & run FROM THE REPO ROOT (shader path + DXC DLLs are resolved relative to it):
//   odin run odin_port/C6_BoxGrid -debug
package c6_box_grid

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

// C++: inline constexpr UINT BOX_GRID_SIZE = 3; BOX_COUNT = BOX_GRID_SIZE*BOX_GRID_SIZE;
BOX_GRID_SIZE :: 3
BOX_COUNT :: BOX_GRID_SIZE * BOX_GRID_SIZE

// C++: struct ColorVertex { XMFLOAT3 Pos; XMFLOAT4 Color; };
Color_Vertex :: struct {
	pos:   [3]f32,
	color: [4]f32,
}

// C++: struct ObjectConstants { XMFLOAT4X4 World; };
Object_Constants :: struct {
	world: d3d_math.Mat4,
}

// C++: struct PassConstants { XMFLOAT4X4 ViewProj; };
Pass_Constants :: struct {
	view_proj: d3d_math.Mat4,
}

// C++: enum ROOT_ARG { ROOT_ARG_OBJECT_CBV = 0, ROOT_ARG_PASS_CBV, ROOT_ARG_COUNT };
Root_Arg :: enum u32 {
	OBJECT_CBV = 0,
	PASS_CBV,
}

Box_Grid_App :: struct {
	using base:          common.D3D_App,
	cbv_srv_uav_heap:    common.Cbv_Srv_Uav_Heap,

	root_signature:      ^d3d12.IRootSignature,

	box_cb_heap_index:   [BOX_COUNT]u32,
	object_cb:           common.Upload_Buffer(Object_Constants),
	pass_cb_heap_index:  u32,
	pass_cb:             common.Upload_Buffer(Pass_Constants),

	box_geo:             common.Mesh_Geometry,

	vs_byte_code:        ^dxc.IBlob,
	ps_byte_code:        ^dxc.IBlob,

	input_layout:        [2]d3d12.INPUT_ELEMENT_DESC,

	solid_pso:           ^d3d12.IPipelineState,
	wireframe_pso:       ^d3d12.IPipelineState,

	world:               [BOX_COUNT]d3d_math.Mat4,
	view:                d3d_math.Mat4,
	proj:                d3d_math.Mat4,

	theta:               f32,
	phi:                 f32,
	radius:              f32,

	last_mouse_pos:      [2]i32, // C++: POINT mLastMousePos

	draw_wireframe:      bool,

	video_mem_poll_time: f32,
	video_mem_info:      dxgi.QUERY_VIDEO_MEMORY_INFO,
}

main :: proc() {
	context = common.mem_track_init() // Odin-side leak detection (debug builds); see common/mem_track.odin

	app: Box_Grid_App

	// C++ member initializers (BoxGridApp.h) — radius starts at 15 to see the whole grid.
	app.view = d3d_math.MAT4_IDENTITY
	app.proj = d3d_math.MAT4_IDENTITY
	app.theta = 1.25 * math.PI
	app.phi = 0.25 * math.PI
	app.radius = 15.0

	app.update = update
	app.draw = draw
	app.on_resize = on_resize
	app.on_mouse_down = on_mouse_down
	app.on_mouse_up = on_mouse_up
	app.on_mouse_move = on_mouse_move

	// C++: BoxGridApp::Initialize().
	common.d3d_app_init(&app.base)

	// We will upload on the direct queue for the book samples, but
	// copy queue would be better for real game.
	upload_batch: common.Resource_Upload_Batch
	common.upload_batch_begin(&upload_batch, app.device)

	build_box_geometry(&app, &upload_batch)

	// (C++ overlaps the upload with the rest of init via std::future; see C6_Box.)
	common.upload_batch_end_and_wait(&upload_batch, app.command_queue)

	// Other init work...
	build_cbv_srv_uav_descriptor_heap(&app)
	build_constant_buffers(&app)
	build_root_signature(&app)
	build_shaders_and_input_layout(&app)
	build_pso(&app)

	// Position boxes in a grid in xz-plane.
	box_spacing: f32 = 5.0
	for i in 0 ..< BOX_GRID_SIZE {
		for j in 0 ..< BOX_GRID_SIZE {
			x := -box_spacing + f32(j) * box_spacing
			z := +box_spacing - f32(i) * box_spacing

			app.world[i * BOX_GRID_SIZE + j] = d3d_math.translation(x, 0.0, z)
		}
	}

	// C++: theApp.Run();
	code := common.d3d_app_run(&app.base)

	// Teardown, C++ destructor order: ImGui first, then the demo's own objects, then the
	// heap, then the base — whose final leak report should stay silent.
	common.d3d_app_shutdown_imgui(&app.base)
	if app.wireframe_pso != nil {app.wireframe_pso->Release()}
	if app.solid_pso != nil {app.solid_pso->Release()}
	if app.ps_byte_code != nil {app.ps_byte_code->Release()}
	if app.vs_byte_code != nil {app.vs_byte_code->Release()}
	if app.root_signature != nil {app.root_signature->Release()}
	common.upload_buffer_destroy(&app.pass_cb)
	common.upload_buffer_destroy(&app.object_cb)
	common.mesh_geometry_destroy(&app.box_geo)
	common.cbv_srv_uav_heap_destroy(&app.cbv_srv_uav_heap)
	common.d3d_app_shutdown(&app.base)
	common.mem_track_report() // before os.exit — os.exit skips defers
	os.exit(code)
}

// C++: BoxGridApp::OnResize.
on_resize :: proc(base: ^common.D3D_App) {
	app := (^Box_Grid_App)(base)

	common.on_resize(base) // C++: D3DApp::OnResize();

	// The window resized, so update the aspect ratio and recompute the projection matrix.
	app.proj = d3d_math.perspective_fov_lh(
		0.25 * math.PI,
		common.aspect_ratio(base),
		1.0,
		1000.0,
	)
}

// C++: BoxGridApp::Update.
update :: proc(base: ^common.D3D_App) {
	app := (^Box_Grid_App)(base)

	// Convert Spherical to Cartesian coordinates.
	x := app.radius * math.sin(app.phi) * math.cos(app.theta)
	z := app.radius * math.sin(app.phi) * math.sin(app.theta)
	y := app.radius * math.cos(app.phi)

	// Build the view matrix.
	pos := d3d_math.Vec3{x, y, z}
	target := d3d_math.Vec3{0, 0, 0}
	up := d3d_math.Vec3{0, 1, 0}
	app.view = d3d_math.look_at_lh(pos, target, up)

	// Update the per-object buffer with the latest world matrix.
	for i in 0 ..< BOX_COUNT {
		obj_constants := Object_Constants {
			world = linalg.transpose(app.world[i]),
		}
		common.copy_data(&app.object_cb, i, obj_constants)
	}

	// Update the per-pass buffer with the latest viewProj matrix.
	view_proj := app.view * app.proj // C++: view*proj — book order, preserved verbatim

	pass_constants := Pass_Constants {
		view_proj = linalg.transpose(view_proj),
	}
	common.copy_data(&app.pass_cb, 0, pass_constants)
}

// C++: BoxGridApp::UpdateImgui — identical to C6_Box's panel.
update_imgui :: proc(app: ^Box_Grid_App) {
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
	// (C++ has a GraphicsMemoryStatistics section here — see C6_Box.)

	im.End()

	im.Render()
}

// C++: BoxGridApp::Draw.
draw :: proc(base: ^common.D3D_App) {
	app := (^Box_Grid_App)(base)

	update_imgui(app) // C++: UpdateImgui(gt) at the top of Draw

	// Reuse the memory associated with command recording.
	// We can only reset when the associated command lists have finished execution on the GPU.
	common.hr_panic(base.direct_cmd_list_alloc->Reset(), "CommandAllocator Reset")

	// A command list can be reset after it has been added to the command queue via
	// ExecuteCommandList. Reusing the command list reuses memory.
	common.hr_panic(
		base.command_list->Reset(base.direct_cmd_list_alloc, app.solid_pso),
		"CommandList Reset",
	)

	descriptor_heaps := [?]^d3d12.IDescriptorHeap{app.cbv_srv_uav_heap.heap}
	base.command_list->SetDescriptorHeaps(len(descriptor_heaps), &descriptor_heaps[0])

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

	base.command_list->SetPipelineState(app.draw_wireframe ? app.wireframe_pso : app.solid_pso)
	base.command_list->SetGraphicsRootSignature(app.root_signature)

	// Pass constants bind once for the whole frame...
	base.command_list->SetGraphicsRootDescriptorTable(
		u32(Root_Arg.PASS_CBV),
		common.gpu_handle(&app.cbv_srv_uav_heap, app.pass_cb_heap_index),
	)

	vbv := common.vertex_buffer_view(&app.box_geo)
	ibv := common.index_buffer_view(&app.box_geo)
	base.command_list->IASetVertexBuffers(0, 1, &vbv)
	base.command_list->IASetIndexBuffer(&ibv)
	base.command_list->IASetPrimitiveTopology(.TRIANGLELIST)

	// ...the object table is re-pointed per box.
	box := app.box_geo.draw_args["box"]
	for i in 0 ..< BOX_COUNT {
		base.command_list->SetGraphicsRootDescriptorTable(
			u32(Root_Arg.OBJECT_CBV),
			common.gpu_handle(&app.cbv_srv_uav_heap, app.box_cb_heap_index[i]),
		)

		base.command_list->DrawIndexedInstanced(
			box.index_count,
			1, // instanceCount
			box.start_index_location,
			box.base_vertex_location,
			0, // startInstanceLocation
		)
	}

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

	// Swap the back and front buffers.
	present_params := dxgi.PRESENT_PARAMETERS{}
	common.hr_panic(base.swap_chain->Present1(0, {}, &present_params), "Present1")
	base.curr_back_buffer = (base.curr_back_buffer + 1) % common.SWAP_CHAIN_BUFFER_COUNT

	// Wait until frame commands are complete.  This waiting is inefficient and is
	// done for simplicity.  Later we will show how to organize our rendering code
	// so we do not have to wait per frame.
	common.flush_command_queue(base)
}

// C++: BoxGridApp::OnMouseDown — ImGui gets first claim on the mouse.
on_mouse_down :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Box_Grid_App)(base)
	io := im.GetIO()
	if !io.WantCaptureMouse {
		app.last_mouse_pos = {x, y}
		win.SetCapture(base.hwnd)
	}
}

// C++: BoxGridApp::OnMouseUp.
on_mouse_up :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	io := im.GetIO()
	if !io.WantCaptureMouse {
		win.ReleaseCapture()
	}
}

// C++: BoxGridApp::OnMouseMove.
on_mouse_move :: proc(base: ^common.D3D_App, btn_state: win.WPARAM, x, y: i32) {
	app := (^Box_Grid_App)(base)
	io := im.GetIO()
	if !io.WantCaptureMouse {
		if btn_state & win.MK_LBUTTON != 0 {
			// Make each pixel correspond to a quarter of a degree.
			dx := math.to_radians(0.25 * f32(x - app.last_mouse_pos.x))
			dy := math.to_radians(0.25 * f32(y - app.last_mouse_pos.y))

			// Update angles based on input to orbit camera around box.
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
			app.radius = clamp(app.radius, 3.0, 15.0)
		}

		app.last_mouse_pos = {x, y}
	}
}

// C++: BoxGridApp::BuildCbvSrvUavDescriptorHeap.
build_cbv_srv_uav_descriptor_heap :: proc(app: ^Box_Grid_App) {
	common.cbv_srv_uav_heap_init(&app.cbv_srv_uav_heap, app.device, CBV_SRV_UAV_HEAP_CAPACITY)
	common.d3d_app_init_imgui(&app.base, &app.cbv_srv_uav_heap)
}

// C++: BoxGridApp::BuildConstantBuffers.
build_constant_buffers :: proc(app: ^Box_Grid_App) {
	is_constant_buffer :: true

	//
	// CB per object — ONE buffer with BOX_COUNT elements, one CBV per element.
	//
	common.upload_buffer_init(&app.object_cb, app.device, BOX_COUNT, is_constant_buffer)

	// Constant buffers must be a multiple of the
	// minimum hardware allocation size (usually 256 bytes).
	obj_cb_byte_size := common.calc_constant_buffer_byte_size(size_of(Object_Constants))

	for cb_obj_index in 0 ..< u32(BOX_COUNT) {
		obj_cb_address :=
			app.object_cb.upload_buffer->GetGPUVirtualAddress() +
			u64(cb_obj_index) * u64(obj_cb_byte_size)

		cbv_obj := d3d12.CONSTANT_BUFFER_VIEW_DESC {
			BufferLocation = obj_cb_address,
			SizeInBytes    = obj_cb_byte_size,
		}

		app.box_cb_heap_index[cb_obj_index] = common.next_free_index(&app.cbv_srv_uav_heap)

		app.device->CreateConstantBufferView(
			&cbv_obj,
			common.cpu_handle(&app.cbv_srv_uav_heap, app.box_cb_heap_index[cb_obj_index]),
		)
	}

	//
	// Pass CB
	//
	app.pass_cb_heap_index = common.next_free_index(&app.cbv_srv_uav_heap)

	num_pass_cb :: 1
	common.upload_buffer_init(&app.pass_cb, app.device, num_pass_cb, is_constant_buffer)

	pass_cb_byte_size := common.calc_constant_buffer_byte_size(size_of(Pass_Constants))

	cb_pass_element_offset := 0
	pass_cb_address :=
		app.pass_cb.upload_buffer->GetGPUVirtualAddress() +
		u64(cb_pass_element_offset) * u64(pass_cb_byte_size)

	cbv_pass_desc := d3d12.CONSTANT_BUFFER_VIEW_DESC {
		BufferLocation = pass_cb_address,
		SizeInBytes    = pass_cb_byte_size,
	}
	app.device->CreateConstantBufferView(
		&cbv_pass_desc,
		common.cpu_handle(&app.cbv_srv_uav_heap, app.pass_cb_heap_index),
	)
}

// C++: BoxGridApp::BuildRootSignature — identical to C6_Box's.
build_root_signature :: proc(app: ^Box_Grid_App) {
	// Root parameter can be a table, root descriptor or root constants.
	slot_root_parameter: [Root_Arg]d3d12.ROOT_PARAMETER

	// Create a table for per-object constants. Arguments would need to be
	// set once per object.
	object_cbv_table := d3d12.DESCRIPTOR_RANGE {
		RangeType          = .CBV,
		NumDescriptors     = 1,
		BaseShaderRegister = 0,
	}

	// Create a table for per-pass constants. Arguments would need to be
	// set once per pass.
	pass_cbv_table := d3d12.DESCRIPTOR_RANGE {
		RangeType          = .CBV,
		NumDescriptors     = 1,
		BaseShaderRegister = 1,
	}

	slot_root_parameter[.OBJECT_CBV] = {
		ParameterType = .DESCRIPTOR_TABLE,
		DescriptorTable = {1, &object_cbv_table},
		ShaderVisibility = .ALL,
	}
	slot_root_parameter[.PASS_CBV] = {
		ParameterType = .DESCRIPTOR_TABLE,
		DescriptorTable = {1, &pass_cbv_table},
		ShaderVisibility = .ALL,
	}

	// A root signature is an array of root parameters.
	root_sig_desc := d3d12.ROOT_SIGNATURE_DESC {
		NumParameters = len(Root_Arg),
		pParameters   = &slot_root_parameter[.OBJECT_CBV],
		Flags         = {.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT},
	}

	// create a root signature
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

// C++: BoxGridApp::BuildShadersAndInputLayout — identical to C6_Box's.
build_shaders_and_input_layout :: proc(app: ^Box_Grid_App) {
	// C++: COMMA_DEBUG_ARGS — DXC_ARG_DEBUG, DXC_ARG_SKIP_OPTIMIZATIONS in debug builds.
	when ODIN_DEBUG {
		vs_args := [?]string{"-E", "VS", "-T", "vs_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
		ps_args := [?]string{"-E", "PS", "-T", "ps_6_6", dxc.ARG_DEBUG, dxc.ARG_SKIP_OPTIMIZATIONS}
	} else {
		vs_args := [?]string{"-E", "VS", "-T", "vs_6_6"}
		ps_args := [?]string{"-E", "PS", "-T", "ps_6_6"}
	}

	app.vs_byte_code = common.compile_shader("Shaders/BasicColor.hlsl", vs_args[:])
	app.ps_byte_code = common.compile_shader("Shaders/BasicColor.hlsl", ps_args[:])

	app.input_layout = {
		{"POSITION", 0, .R32G32B32_FLOAT, 0, 0, .PER_VERTEX_DATA, 0},
		{"COLOR", 0, .R32G32B32A32_FLOAT, 0, 12, .PER_VERTEX_DATA, 0},
	}
}

// C++: BoxGridApp::BuildBoxGeometry — identical to C6_Box's.
build_box_geometry :: proc(app: ^Box_Grid_App, upload_batch: ^common.Resource_Upload_Batch) {
	// C++: DirectX::Colors::* (DirectXColors.h) — note Green is the X11 half-green.
	vertices := [8]Color_Vertex {
		{{-1.0, -1.0, -1.0}, {1, 1, 1, 1}}, // White
		{{-1.0, +1.0, -1.0}, {0, 0, 0, 1}}, // Black
		{{+1.0, +1.0, -1.0}, {1, 0, 0, 1}}, // Red
		{{+1.0, -1.0, -1.0}, {0, 0.501960814, 0, 1}}, // Green
		{{-1.0, -1.0, +1.0}, {0, 0, 1, 1}}, // Blue
		{{-1.0, +1.0, +1.0}, {1, 1, 0, 1}}, // Yellow
		{{+1.0, +1.0, +1.0}, {0, 1, 1, 1}}, // Cyan
		{{+1.0, -1.0, +1.0}, {1, 0, 1, 1}}, // Magenta
	}

	indices := [36]u16 {
		// front face
		0, 1, 2,
		0, 2, 3,

		// back face
		4, 6, 5,
		4, 7, 6,

		// left face
		4, 5, 1,
		4, 1, 0,

		// right face
		3, 2, 6,
		3, 6, 7,

		// top face
		1, 5, 6,
		1, 6, 2,

		// bottom face
		4, 0, 3,
		4, 3, 7,
	}

	vb_byte_size := u32(len(vertices) * size_of(Color_Vertex))
	ib_byte_size := u32(len(indices) * size_of(u16))

	app.box_geo.name = "boxGeo"

	app.box_geo.vertex_buffer_cpu = slice.clone(slice.to_bytes(vertices[:]))
	app.box_geo.index_buffer_cpu = slice.clone(slice.to_bytes(indices[:]))

	common.create_static_buffer(
		upload_batch,
		&vertices[0],
		len(vertices),
		size_of(Color_Vertex),
		{.VERTEX_AND_CONSTANT_BUFFER},
		&app.box_geo.vertex_buffer_gpu,
	)

	common.create_static_buffer(
		upload_batch,
		&indices[0],
		len(indices),
		size_of(u16),
		{.INDEX_BUFFER},
		&app.box_geo.index_buffer_gpu,
	)

	app.box_geo.vertex_byte_stride = size_of(Color_Vertex)
	app.box_geo.vertex_buffer_byte_size = vb_byte_size
	app.box_geo.index_format = .R16_UINT
	app.box_geo.index_buffer_byte_size = ib_byte_size

	// Box that tightly contains all the geometry. This
	// is used in later chapters of the book.
	submesh := common.Submesh_Geometry {
		index_count          = len(indices),
		start_index_location = 0,
		base_vertex_location = 0,
		vertex_count         = 8,
		bounds               = {center = {0, 0, 0}, extents = {1, 1, 1}},
	}

	app.box_geo.draw_args["box"] = submesh
}

// C++: BoxGridApp::BuildPSO — identical to C6_Box's.
build_pso :: proc(app: ^Box_Grid_App) {
	base_pso_desc := common.init_default_pso(
		app.back_buffer_format,
		app.depth_stencil_format,
		app.input_layout[:],
		app.root_signature,
		app.vs_byte_code,
		app.ps_byte_code,
	)

	common.hr_panic(
		app.device->CreateGraphicsPipelineState(
			&base_pso_desc,
			d3d12.IPipelineState_UUID,
			common.ptr(&app.solid_pso),
		),
		"CreateGraphicsPipelineState(solid)",
	)

	// Create a new PSO based off the default PSO:
	wireframe_pso_desc := base_pso_desc
	wireframe_pso_desc.RasterizerState.FillMode = .WIREFRAME

	common.hr_panic(
		app.device->CreateGraphicsPipelineState(
			&wireframe_pso_desc,
			d3d12.IPipelineState_UUID,
			common.ptr(&app.wireframe_pso),
		),
		"CreateGraphicsPipelineState(wireframe)",
	)
}
