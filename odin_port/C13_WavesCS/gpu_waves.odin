// Port of Demos/C13_WavesCS/GpuWaves.{h,cpp}. The finite-difference solver runs in
// WaveSim.hlsl over three ping-pong R32_FLOAT textures; the current solution is sampled
// by BasicBlend.hlsl to displace the water-grid vertices.
package c13_waves_cs

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import common "../common"

Gpu_Waves :: struct {
	num_rows, num_cols:        u32,
	vertex_count:              u32,
	triangle_count:            u32,
	k:                         [3]f32,
	time_step, spatial_step:   f32,
	time_accumulator:          f32,

	prev_sol_srv_index:        u32,
	curr_sol_srv_index:        u32,
	next_sol_srv_index:        u32,
	prev_sol_uav_index:        u32,
	curr_sol_uav_index:        u32,
	next_sol_uav_index:        u32,

	prev_sol:                  ^d3d12.IResource,
	curr_sol:                  ^d3d12.IResource,
	next_sol:                  ^d3d12.IResource,
	curr_is_shader_resource:   bool,
}

gpu_waves_init :: proc(
	waves: ^Gpu_Waves,
	upload_batch: ^common.Resource_Upload_Batch,
	m, n: u32,
	dx, dt, speed, damping: f32,
) {
	assert((m * n) % 256 == 0)
	waves.num_rows = m
	waves.num_cols = n
	waves.vertex_count = m * n
	waves.triangle_count = (m - 1) * (n - 1) * 2
	waves.time_step = dt
	waves.spatial_step = dx
	gpu_waves_set_constants(waves, speed, damping)

	zeroes := make([]f32, waves.vertex_count, context.temp_allocator)
	destinations := [?]^^d3d12.IResource{&waves.prev_sol, &waves.curr_sol, &waves.next_sol}
	for destination in destinations {
		destination^ = common.create_texture_2d_from_memory(
			upload_batch,
			n,
			m,
			.R32_FLOAT,
			raw_data(zeroes),
			n * size_of(f32),
			{.UNORDERED_ACCESS},
			{.ALLOW_UNORDERED_ACCESS},
		)
	}
}

gpu_waves_destroy :: proc(waves: ^Gpu_Waves) {
	if waves.prev_sol != nil {waves.prev_sol->Release()}
	if waves.curr_sol != nil {waves.curr_sol->Release()}
	if waves.next_sol != nil {waves.next_sol->Release()}
	waves^ = {}
}

gpu_waves_set_constants :: proc(waves: ^Gpu_Waves, speed, damping: f32) {
	d := damping * waves.time_step + 2.0
	e := speed * speed * waves.time_step * waves.time_step /
		(waves.spatial_step * waves.spatial_step)
	waves.k[0] = (damping * waves.time_step - 2.0) / d
	waves.k[1] = (4.0 - 8.0 * e) / d
	waves.k[2] = 2.0 * e / d
}

gpu_waves_width :: proc(waves: ^Gpu_Waves) -> f32 {
	return f32(waves.num_cols) * waves.spatial_step
}

gpu_waves_depth :: proc(waves: ^Gpu_Waves) -> f32 {
	return f32(waves.num_rows) * waves.spatial_step
}

gpu_waves_displacement_map_srv_index :: proc(waves: ^Gpu_Waves) -> u32 {
	return waves.curr_sol_srv_index
}

gpu_waves_build_descriptors :: proc(
	waves: ^Gpu_Waves,
	device: ^d3d12.IDevice5,
	heap: ^common.Cbv_Srv_Uav_Heap,
) {
	waves.prev_sol_srv_index = common.next_free_index(heap)
	waves.curr_sol_srv_index = common.next_free_index(heap)
	waves.next_sol_srv_index = common.next_free_index(heap)
	waves.prev_sol_uav_index = common.next_free_index(heap)
	waves.curr_sol_uav_index = common.next_free_index(heap)
	waves.next_sol_uav_index = common.next_free_index(heap)

	common.create_srv_2d(device, waves.prev_sol, .R32_FLOAT, 1, common.cpu_handle(heap, waves.prev_sol_srv_index))
	common.create_srv_2d(device, waves.curr_sol, .R32_FLOAT, 1, common.cpu_handle(heap, waves.curr_sol_srv_index))
	common.create_srv_2d(device, waves.next_sol, .R32_FLOAT, 1, common.cpu_handle(heap, waves.next_sol_srv_index))
	common.create_uav_2d(device, waves.prev_sol, .R32_FLOAT, 0, common.cpu_handle(heap, waves.prev_sol_uav_index))
	common.create_uav_2d(device, waves.curr_sol, .R32_FLOAT, 0, common.cpu_handle(heap, waves.curr_sol_uav_index))
	common.create_uav_2d(device, waves.next_sol, .R32_FLOAT, 0, common.cpu_handle(heap, waves.next_sol_uav_index))
}

gpu_waves_prepare_compute :: proc(waves: ^Gpu_Waves, cmd_list: ^d3d12.IGraphicsCommandList6) {
	if waves.curr_is_shader_resource {
		barrier := common.transition_barrier(
			waves.curr_sol, {.NON_PIXEL_SHADER_RESOURCE}, {.UNORDERED_ACCESS},
		)
		cmd_list->ResourceBarrier(1, &barrier)
		waves.curr_is_shader_resource = false
	}
}

gpu_waves_prepare_render :: proc(waves: ^Gpu_Waves, cmd_list: ^d3d12.IGraphicsCommandList6) {
	if !waves.curr_is_shader_resource {
		barrier := common.transition_barrier(
			waves.curr_sol, {.UNORDERED_ACCESS}, {.NON_PIXEL_SHADER_RESOURCE},
		)
		cmd_list->ResourceBarrier(1, &barrier)
		waves.curr_is_shader_resource = true
	}
}

gpu_waves_cb :: proc(waves: ^Gpu_Waves) -> common.Gpu_Waves_CB {
	return {
		wave_constant0 = waves.k[0],
		wave_constant1 = waves.k[1],
		wave_constant2 = waves.k[2],
		grid_size = {waves.num_cols, waves.num_rows},
		prev_sol_index = waves.prev_sol_uav_index,
		curr_sol_index = waves.curr_sol_uav_index,
		output_index = waves.next_sol_uav_index,
	}
}

gpu_waves_disturb :: proc(
	waves: ^Gpu_Waves,
	cmd_list: ^d3d12.IGraphicsCommandList6,
	root_signature: ^d3d12.IRootSignature,
	pass_cb: ^d3d12.IResource,
	pso: ^d3d12.IPipelineState,
	linear_allocator: ^common.Graphics_Memory,
	i, j: u32,
	magnitude: f32,
) {
	gpu_waves_prepare_compute(waves, cmd_list)
	cmd_list->SetPipelineState(pso)
	cmd_list->SetComputeRootSignature(root_signature)
	cmd_list->SetComputeRootConstantBufferView(
		u32(Compute_Root_Arg.PASS_CBV), pass_cb->GetGPUVirtualAddress(),
	)
	cb := gpu_waves_cb(waves)
	cb.disturb_mag = magnitude
	cb.disturb_index = {j, i}
	handle := common.allocate_constant(linear_allocator, cb)
	cmd_list->SetComputeRootConstantBufferView(
		u32(Compute_Root_Arg.DISPATCH_CBV), handle.gpu_address,
	)
	cmd_list->Dispatch(1, 1, 1)
	barrier := common.uav_barrier(waves.curr_sol)
	cmd_list->ResourceBarrier(1, &barrier)
}

gpu_waves_update :: proc(
	waves: ^Gpu_Waves,
	delta_time: f32,
	cmd_list: ^d3d12.IGraphicsCommandList6,
	root_signature: ^d3d12.IRootSignature,
	pass_cb: ^d3d12.IResource,
	pso: ^d3d12.IPipelineState,
	linear_allocator: ^common.Graphics_Memory,
) {
	waves.time_accumulator += delta_time
	if waves.time_accumulator < waves.time_step {
		return
	}

	gpu_waves_prepare_compute(waves, cmd_list)
	cmd_list->SetPipelineState(pso)
	cmd_list->SetComputeRootSignature(root_signature)
	cmd_list->SetComputeRootConstantBufferView(
		u32(Compute_Root_Arg.PASS_CBV), pass_cb->GetGPUVirtualAddress(),
	)
	handle := common.allocate_constant(linear_allocator, gpu_waves_cb(waves))
	cmd_list->SetComputeRootConstantBufferView(
		u32(Compute_Root_Arg.DISPATCH_CBV), handle.gpu_address,
	)
	cmd_list->Dispatch(waves.num_cols / 16, waves.num_rows / 16, 1)
	barrier := common.uav_barrier(waves.next_sol)
	cmd_list->ResourceBarrier(1, &barrier)

	waves.prev_sol, waves.curr_sol, waves.next_sol =
		waves.curr_sol, waves.next_sol, waves.prev_sol
	waves.prev_sol_srv_index, waves.curr_sol_srv_index, waves.next_sol_srv_index =
		waves.curr_sol_srv_index, waves.next_sol_srv_index, waves.prev_sol_srv_index
	waves.prev_sol_uav_index, waves.curr_sol_uav_index, waves.next_sol_uav_index =
		waves.curr_sol_uav_index, waves.next_sol_uav_index, waves.prev_sol_uav_index
	waves.time_accumulator = 0
}
