// Partial port of `Common/DescriptorUtil.h/.cpp` (Frank Luna).
//
// Descriptor_Heap (RTV/DSV) and Cbv_Srv_Uav_Heap are ported; the book's SamplerHeap
// arrives with the first demos that bind samplers. The C++ heaps are singletons — the
// port passes them explicitly instead.
package common

import d3d12 "vendor:directx/d3d12"

// A descriptor heap plus the handle arithmetic the book wraps in CpuHandle(i)/GpuHandle(i):
// heap_start + index * increment_size.
Descriptor_Heap :: struct {
	heap:            ^d3d12.IDescriptorHeap,
	descriptor_size: u32,
}

// C++: DescriptorHeap::Init(device, type, capacity).
descriptor_heap_init :: proc(
	dh: ^Descriptor_Heap,
	device: ^d3d12.IDevice5,
	type: d3d12.DESCRIPTOR_HEAP_TYPE,
	capacity: u32,
) {
	// CBV/SRV/UAV and sampler heaps are the shader-visible kinds; RTV/DSV heaps are
	// CPU-only and must not set the flag.
	shader_visible := type == .CBV_SRV_UAV || type == .SAMPLER
	desc := d3d12.DESCRIPTOR_HEAP_DESC {
		Type           = type,
		NumDescriptors = capacity,
		Flags          = shader_visible ? {.SHADER_VISIBLE} : {},
		NodeMask       = 0,
	}
	hr_panic(
		device->CreateDescriptorHeap(&desc, d3d12.IDescriptorHeap_UUID, ptr(&dh.heap)),
		"CreateDescriptorHeap",
	)
	dh.descriptor_size = device->GetDescriptorHandleIncrementSize(type)
}

descriptor_heap_destroy :: proc(dh: ^Descriptor_Heap) {
	if dh.heap != nil {
		dh.heap->Release()
		dh.heap = nil
	}
}

// C++: CpuHandle(index).
cpu_handle :: proc(dh: ^Descriptor_Heap, index: u32) -> d3d12.CPU_DESCRIPTOR_HANDLE {
	handle: d3d12.CPU_DESCRIPTOR_HANDLE
	dh.heap->GetCPUDescriptorHandleForHeapStart(&handle)
	handle.ptr += uint(index) * uint(dh.descriptor_size)
	return handle
}

// C++: GpuHandle(index). Only valid on shader-visible heaps.
gpu_handle :: proc(dh: ^Descriptor_Heap, index: u32) -> d3d12.GPU_DESCRIPTOR_HANDLE {
	handle: d3d12.GPU_DESCRIPTOR_HANDLE
	dh.heap->GetGPUDescriptorHandleForHeapStart(&handle)
	handle.ptr += u64(index) * u64(dh.descriptor_size)
	return handle
}

// C++: CbvSrvUavHeap — the bindless free-index allocator: when a resource is created,
// request a free index; when it is destroyed, release the index for reuse. Shaders
// reference resources by heap index (SM 6.6 ResourceDescriptorHeap[]), so the index IS
// the contract.
Cbv_Srv_Uav_Heap :: struct {
	using base:   Descriptor_Heap,
	free_indices: [dynamic]u32,
	used_indices: map[u32]bool, // validation (the C++ keeps an unordered_set; debug aid)
}

// C++: CbvSrvUavHeap::Init(device, capacity).
cbv_srv_uav_heap_init :: proc(h: ^Cbv_Srv_Uav_Heap, device: ^d3d12.IDevice5, capacity: u32) {
	descriptor_heap_init(&h.base, device, .CBV_SRV_UAV, capacity)
	reserve(&h.free_indices, int(capacity))
	// Filled in reverse so pop() hands out ascending indices, like the C++ queue.
	for i := int(capacity) - 1; i >= 0; i -= 1 {
		append(&h.free_indices, u32(i))
	}
}

cbv_srv_uav_heap_destroy :: proc(h: ^Cbv_Srv_Uav_Heap) {
	delete(h.free_indices)
	delete(h.used_indices)
	descriptor_heap_destroy(&h.base)
}

// C++: CbvSrvUavHeap::NextFreeIndex().
next_free_index :: proc(h: ^Cbv_Srv_Uav_Heap) -> u32 {
	assert(len(h.free_indices) > 0, "CbvSrvUavHeap exhausted")
	index := pop(&h.free_indices)
	h.used_indices[index] = true
	return index
}

// C++: CbvSrvUavHeap::ReleaseIndex(index).
release_index :: proc(h: ^Cbv_Srv_Uav_Heap, index: u32) {
	assert(index in h.used_indices, "releasing an index that was never handed out")
	delete_key(&h.used_indices, index)
	append(&h.free_indices, index)
}
