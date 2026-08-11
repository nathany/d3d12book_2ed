// Port of Demos/C13_Blur/BlurFilter.{h,cpp}. A separable Gaussian compute filter
// ping-pongs between two UAV-capable textures that match the swap-chain dimensions.
package c13_blur

import "core:math"
import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"
import common "../common"

MAX_BLUR_RADIUS :: 15

Blur_Filter :: struct {
	device:              ^d3d12.IDevice5,
	heap:                ^common.Cbv_Srv_Uav_Heap,
	width, height:       u32,
	format:              dxgi.FORMAT,
	blur0_srv_index:     u32,
	blur1_srv_index:     u32,
	blur0_uav_index:     u32,
	blur1_uav_index:     u32,
	blur_map0:           ^d3d12.IResource,
	blur_map1:           ^d3d12.IResource,
	descriptors_allocated: bool,
	initialized:         bool,
}

blur_filter_init :: proc(
	filter: ^Blur_Filter,
	device: ^d3d12.IDevice5,
	width, height: u32,
	format: dxgi.FORMAT,
) {
	filter.device = device
	filter.width = width
	filter.height = height
	filter.format = format
	filter.initialized = true
	blur_filter_build_resources(filter)
}

blur_filter_destroy :: proc(filter: ^Blur_Filter) {
	if filter.blur_map0 != nil {filter.blur_map0->Release()}
	if filter.blur_map1 != nil {filter.blur_map1->Release()}
	filter^ = {}
}

blur_filter_output :: proc(filter: ^Blur_Filter) -> ^d3d12.IResource {
	return filter.blur_map0
}

blur_filter_build_resources :: proc(filter: ^Blur_Filter) {
	if filter.blur_map0 != nil {filter.blur_map0->Release()}
	if filter.blur_map1 != nil {filter.blur_map1->Release()}
	filter.blur_map0 = nil
	filter.blur_map1 = nil

	desc := d3d12.RESOURCE_DESC {
		Dimension = .TEXTURE2D,
		Width = u64(filter.width),
		Height = filter.height,
		DepthOrArraySize = 1,
		MipLevels = 1,
		Format = filter.format,
		SampleDesc = {Count = 1},
		Layout = .UNKNOWN,
		Flags = {.ALLOW_UNORDERED_ACCESS},
	}
	heap := d3d12.HEAP_PROPERTIES{Type = .DEFAULT}
	destinations := [?]^^d3d12.IResource{&filter.blur_map0, &filter.blur_map1}
	for destination in destinations {
		common.hr_panic(
			filter.device->CreateCommittedResource(
				&heap, {}, &desc, {.NON_PIXEL_SHADER_RESOURCE}, nil,
				d3d12.IResource_UUID, common.ptr(destination),
			),
			"CreateCommittedResource(blur map)",
		)
	}
}

blur_filter_build_descriptors :: proc(
	filter: ^Blur_Filter,
	heap: ^common.Cbv_Srv_Uav_Heap,
) {
	filter.heap = heap
	if !filter.descriptors_allocated {
		filter.blur0_srv_index = common.next_free_index(heap)
		filter.blur1_srv_index = common.next_free_index(heap)
		filter.blur0_uav_index = common.next_free_index(heap)
		filter.blur1_uav_index = common.next_free_index(heap)
		filter.descriptors_allocated = true
	}
	common.create_srv_2d(filter.device, filter.blur_map0, filter.format, 1, common.cpu_handle(heap, filter.blur0_srv_index))
	common.create_srv_2d(filter.device, filter.blur_map1, filter.format, 1, common.cpu_handle(heap, filter.blur1_srv_index))
	common.create_uav_2d(filter.device, filter.blur_map0, filter.format, 0, common.cpu_handle(heap, filter.blur0_uav_index))
	common.create_uav_2d(filter.device, filter.blur_map1, filter.format, 0, common.cpu_handle(heap, filter.blur1_uav_index))
}

blur_filter_on_resize :: proc(filter: ^Blur_Filter, width, height: u32) {
	if !filter.initialized || filter.width == width && filter.height == height {
		return
	}
	filter.width = width
	filter.height = height
	blur_filter_build_resources(filter)
	if filter.heap != nil {
		blur_filter_build_descriptors(filter, filter.heap)
	}
}

blur_filter_calc_weights :: proc(sigma: f32) -> (weights: [31]f32, radius: i32) {
	radius = i32(math.ceil(2.0 * sigma))
	assert(radius <= MAX_BLUR_RADIUS)
	two_sigma_squared := 2.0 * sigma * sigma
	sum: f32
	for i in -radius ..= radius {
		x := f32(i)
		weight := math.exp(-x * x / two_sigma_squared)
		weights[i + radius] = weight
		sum += weight
	}
	for i in 0 ..< 2 * radius + 1 {
		weights[i] /= sum
	}
	return
}

blur_filter_execute :: proc(
	filter: ^Blur_Filter,
	cmd_list: ^d3d12.IGraphicsCommandList6,
	root_signature: ^d3d12.IRootSignature,
	pass_cb: ^d3d12.IResource,
	horz_pso, vert_pso: ^d3d12.IPipelineState,
	input: ^d3d12.IResource,
	blur_count: i32,
	blur_sigma: f32,
	linear_allocator: ^common.Graphics_Memory,
) {
	weights, radius := blur_filter_calc_weights(blur_sigma)
	horizontal_cb: common.Blur_Dispatch_CB
	for weight, i in weights[:2 * radius + 1] {
		horizontal_cb.weight_vec[i / 4][i % 4] = weight
	}
	horizontal_cb.blur_radius = radius
	horizontal_cb.blur_input_index = filter.blur0_srv_index
	horizontal_cb.blur_output_index = filter.blur1_uav_index
	horizontal_handle := common.allocate_constant(linear_allocator, horizontal_cb)

	vertical_cb := horizontal_cb
	vertical_cb.blur_input_index = filter.blur1_srv_index
	vertical_cb.blur_output_index = filter.blur0_uav_index
	vertical_handle := common.allocate_constant(linear_allocator, vertical_cb)

	cmd_list->SetComputeRootSignature(root_signature)
	cmd_list->SetComputeRootConstantBufferView(
		u32(Compute_Root_Arg.PASS_CBV), pass_cb->GetGPUVirtualAddress(),
	)
	barriers := [?]d3d12.RESOURCE_BARRIER {
		common.transition_barrier(input, {.RENDER_TARGET}, {.COPY_SOURCE}),
		common.transition_barrier(filter.blur_map0, {.NON_PIXEL_SHADER_RESOURCE}, {.COPY_DEST}),
	}
	cmd_list->ResourceBarrier(len(barriers), &barriers[0])
	cmd_list->CopyResource(filter.blur_map0, input)
	to_read := common.transition_barrier(
		filter.blur_map0, {.COPY_DEST}, {.NON_PIXEL_SHADER_RESOURCE},
	)
	cmd_list->ResourceBarrier(1, &to_read)

	for _ in 0 ..< blur_count {
		blur1_to_uav := common.transition_barrier(
			filter.blur_map1, {.NON_PIXEL_SHADER_RESOURCE}, {.UNORDERED_ACCESS},
		)
		cmd_list->ResourceBarrier(1, &blur1_to_uav)
		cmd_list->SetComputeRootConstantBufferView(
			u32(Compute_Root_Arg.DISPATCH_CBV), horizontal_handle.gpu_address,
		)
		cmd_list->SetPipelineState(horz_pso)
		cmd_list->Dispatch((filter.width + 255) / 256, filter.height, 1)

		between := [?]d3d12.RESOURCE_BARRIER {
			common.transition_barrier(filter.blur_map0, {.NON_PIXEL_SHADER_RESOURCE}, {.UNORDERED_ACCESS}),
			common.transition_barrier(filter.blur_map1, {.UNORDERED_ACCESS}, {.NON_PIXEL_SHADER_RESOURCE}),
		}
		cmd_list->ResourceBarrier(len(between), &between[0])
		cmd_list->SetComputeRootConstantBufferView(
			u32(Compute_Root_Arg.DISPATCH_CBV), vertical_handle.gpu_address,
		)
		cmd_list->SetPipelineState(vert_pso)
		cmd_list->Dispatch(filter.width, (filter.height + 255) / 256, 1)
		map0_to_read := common.transition_barrier(
			filter.blur_map0, {.UNORDERED_ACCESS}, {.NON_PIXEL_SHADER_RESOURCE},
		)
		cmd_list->ResourceBarrier(1, &map0_to_read)
	}
}
