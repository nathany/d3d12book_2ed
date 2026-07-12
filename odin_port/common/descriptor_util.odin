// Partial port of `Common/DescriptorUtil.h/.cpp` (Frank Luna).
//
// Chapter 4 needs only the plain Descriptor_Heap (RTV + DSV). The book's CbvSrvUavHeap
// (bindless free-index allocator) and SamplerHeap arrive with the first demos that bind
// shader resources; both are C++ singletons — the port will pass them explicitly instead.
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
