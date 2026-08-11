// Port of `Common/DescriptorUtil.h/.cpp` (Frank Luna): Descriptor_Heap (RTV/DSV),
// Cbv_Srv_Uav_Heap (the bindless free-index allocator), Sampler_Heap (ch 9+), and the
// Create*View one-liners. The C++ heaps are singletons — the port passes them explicitly
// instead (Sampler_Heap lives on D3D_App, matching where the C++ Init()s it).
package common

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

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

// C++: SamplerHeap — applications usually only need a handful of samplers, so just
// define them all up front in the sampler heap, and index them in shaders (the SAM_*
// constants in shared_types.odin — the order below IS that contract).
Sampler_Heap :: struct {
	using base: Descriptor_Heap,
}

// C++: the InitSamplerDesc defaults; only what a slot overrides is spelled out below.
@(private = "file")
init_sampler_desc :: proc(
	filter: d3d12.FILTER,
	address_mode: d3d12.TEXTURE_ADDRESS_MODE,
	max_anisotropy: u32 = 16,
	// C++: D3D12_COMPARISON_FUNC_NONE (0) — the vendor enum omits it, so cast.
	comparison_func := d3d12.COMPARISON_FUNC(0),
) -> d3d12.SAMPLER_DESC {
	return {
		Filter = filter,
		AddressU = address_mode,
		AddressV = address_mode,
		AddressW = address_mode,
		MipLODBias = 0,
		MaxAnisotropy = max_anisotropy,
		ComparisonFunc = comparison_func,
		BorderColor = {0, 0, 0, 0},
		MinLOD = 0,
		MaxLOD = d3d12.FLOAT32_MAX,
	}
}

// C++: SamplerHeap::Init(device).
sampler_heap_init :: proc(h: ^Sampler_Heap, device: ^d3d12.IDevice5) {
	capacity :: 16 // C++: bump as needed

	descriptor_heap_init(&h.base, device, .SAMPLER, capacity)

	samplers := [?]d3d12.SAMPLER_DESC {
		SAM_POINT_WRAP   = init_sampler_desc(.MIN_MAG_MIP_POINT, .WRAP),
		SAM_POINT_CLAMP  = init_sampler_desc(.MIN_MAG_MIP_POINT, .CLAMP),
		SAM_LINEAR_WRAP  = init_sampler_desc(.MIN_MAG_MIP_LINEAR, .WRAP),
		SAM_LINEAR_CLAMP = init_sampler_desc(.MIN_MAG_MIP_LINEAR, .CLAMP),
		SAM_ANISO_WRAP   = init_sampler_desc(.ANISOTROPIC, .WRAP, max_anisotropy = 8),
		SAM_ANISO_CLAMP  = init_sampler_desc(.ANISOTROPIC, .CLAMP, max_anisotropy = 8),
		SAM_SHADOW       = init_sampler_desc(
			.COMPARISON_MIN_MAG_LINEAR_MIP_POINT,
			.BORDER,
			comparison_func = .LESS_EQUAL,
		),
	}

	for &desc, i in samplers {
		device->CreateSampler(&desc, cpu_handle(&h.base, u32(i)))
	}
}

// C++: CreateSrv2d (DescriptorUtil.h).
create_srv_2d :: proc(
	device: ^d3d12.IDevice5,
	resource: ^d3d12.IResource,
	format: dxgi.FORMAT,
	mip_levels: u16,
	h_descriptor: d3d12.CPU_DESCRIPTOR_HANDLE,
) {
	srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
		Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
		ViewDimension = .TEXTURE2D,
		Format = format,
	}
	srv_desc.Texture2D = {
		MostDetailedMip     = 0,
		MipLevels           = u32(mip_levels),
		ResourceMinLODClamp = 0.0,
	}
	device->CreateShaderResourceView(resource, &srv_desc, h_descriptor)
}

// C++: CreateSrv2dArray (DescriptorUtil.h).
create_srv_2d_array :: proc(
	device: ^d3d12.IDevice5,
	resource: ^d3d12.IResource,
	format: dxgi.FORMAT,
	mip_levels: u16,
	array_size: u16,
	h_descriptor: d3d12.CPU_DESCRIPTOR_HANDLE,
) {
	srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
		Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
		ViewDimension = .TEXTURE2DARRAY,
		Format = format,
	}
	srv_desc.Texture2DArray = {
		MostDetailedMip = 0,
		MipLevels = u32(mip_levels),
		FirstArraySlice = 0,
		ArraySize = u32(array_size),
		PlaneSlice = 0,
		ResourceMinLODClamp = 0,
	}
	device->CreateShaderResourceView(resource, &srv_desc, h_descriptor)
}

// C++: CreateSrvCube (DescriptorUtil.h).
create_srv_cube :: proc(
	device: ^d3d12.IDevice5,
	resource: ^d3d12.IResource,
	format: dxgi.FORMAT,
	mip_levels: u16,
	h_descriptor: d3d12.CPU_DESCRIPTOR_HANDLE,
) {
	srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
		Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
		ViewDimension = .TEXTURECUBE,
		Format = format,
	}
	srv_desc.TextureCube = {
		MostDetailedMip     = 0,
		MipLevels           = u32(mip_levels),
		ResourceMinLODClamp = 0.0,
	}
	device->CreateShaderResourceView(resource, &srv_desc, h_descriptor)
}
