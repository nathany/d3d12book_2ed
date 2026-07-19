// Port of `Common/UploadBuffer.h` (Frank Luna) — an upload-heap buffer of `element_count`
// T's, persistently mapped so the CPU can rewrite elements every frame (constant buffers,
// dynamic vertex data). The C++ template parameter becomes Odin parametric polymorphism:
// `Upload_Buffer(Object_Constants)`.
package common

import "core:mem"
import d3d12 "vendor:directx/d3d12"

Upload_Buffer :: struct($T: typeid) {
	upload_buffer:      ^d3d12.IResource, // C++: mUploadBuffer (Resource() accessor)
	mapped_data:        [^]byte,
	element_byte_size:  u32,
	is_constant_buffer: bool,
}

// C++: UploadBuffer(device, elementCount, isConstantBuffer).
upload_buffer_init :: proc(
	ub: ^Upload_Buffer($T),
	device: ^d3d12.IDevice5,
	element_count: u32,
	is_constant_buffer: bool,
) {
	ub.is_constant_buffer = is_constant_buffer
	ub.element_byte_size = size_of(T)

	// Constant buffer elements need to be multiples of 256 bytes.
	// This is because the hardware can only view constant data
	// at m*256 byte offsets and of n*256 byte lengths.
	// typedef struct D3D12_CONSTANT_BUFFER_VIEW_DESC {
	// UINT64 OffsetInBytes; // multiple of 256
	// UINT   SizeInBytes;   // multiple of 256
	// } D3D12_CONSTANT_BUFFER_VIEW_DESC;
	if is_constant_buffer {
		ub.element_byte_size = calc_constant_buffer_byte_size(size_of(T))
	}

	heap_properties := d3d12.HEAP_PROPERTIES {
		Type = .UPLOAD,
	}
	desc := buffer_desc(u64(ub.element_byte_size) * u64(element_count))
	hr_panic(
		device->CreateCommittedResource(
			&heap_properties,
			{},
			&desc,
			d3d12.RESOURCE_STATE_GENERIC_READ,
			nil,
			d3d12.IResource_UUID,
			ptr(&ub.upload_buffer),
		),
		"CreateCommittedResource(UploadBuffer)",
	)

	hr_panic(ub.upload_buffer->Map(0, nil, (^rawptr)(&ub.mapped_data)), "Map(UploadBuffer)")

	// We do not need to unmap until we are done with the resource.  However, we must not
	// write to the resource while it is in use by the GPU (so we must use synchronization
	// techniques).
}

// C++: ~UploadBuffer().
upload_buffer_destroy :: proc(ub: ^Upload_Buffer($T)) {
	if ub.upload_buffer != nil {
		ub.upload_buffer->Unmap(0, nil)
		ub.upload_buffer->Release()
		ub.upload_buffer = nil
	}
	ub.mapped_data = nil
}

// C++: CopyData(elementIndex, data) — note sizeof(T) bytes copied, into a slot
// element_byte_size (≥ sizeof(T)) bytes wide.
copy_data :: proc(ub: ^Upload_Buffer($T), element_index: int, data: T) {
	data := data
	mem.copy(&ub.mapped_data[element_index * int(ub.element_byte_size)], &data, size_of(T))
}
