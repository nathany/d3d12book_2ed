// Port of `Demos/C13_Blur/FrameResource.h/.cpp` (Frank Luna). GPU waves and blur share
// the compute-root argument layout while frame resources retain pass/material uploads.
package c13_blur

import d3d12 "vendor:directx/d3d12"
import common "../common"

// C++: enum GFX_ROOT_ARG — named offsets to root parameters in root signature for
// readability.
Gfx_Root_Arg :: enum u32 {
	OBJECT_CBV = 0,
	PASS_CBV,
	MATERIAL_SRV,
}

Compute_Root_Arg :: enum u32 {
	DISPATCH_CBV = 0,
	PASS_CBV,
	PASS_EXTRA_CBV,
}

// Stores the resources needed for the CPU to build the command lists
// for a frame.
Frame_Resource :: struct {
	// We cannot reset the allocator until the GPU is done processing the commands.
	// So each frame needs their own allocator.
	cmd_list_alloc:  ^d3d12.ICommandAllocator,

	// We cannot update a buffer until the GPU is done processing the commands
	// that reference it.  So each frame needs their own buffers.
	pass_cb:         common.Upload_Buffer(common.Per_Pass_CB),
	material_buffer: common.Upload_Buffer(common.Material_Data),

	// Fence value to mark commands up to this fence point.  This lets us
	// check if these frame resources are still in use by the GPU.
	fence:           u64,
}

// C++: FrameResource(device, passCount, materialCount, waveVertCount).
frame_resource_init :: proc(
	fr: ^Frame_Resource,
	device: ^d3d12.IDevice5,
	pass_count: u32,
	material_count: u32,
) {
	common.hr_panic(
		device->CreateCommandAllocator(
			.DIRECT,
			d3d12.ICommandAllocator_UUID,
			common.ptr(&fr.cmd_list_alloc),
		),
		"CreateCommandAllocator(FrameResource)",
	)

	common.upload_buffer_init(&fr.pass_cb, device, pass_count, true)
	// A StructuredBuffer, not a constant buffer — elements stay tightly packed (no
	// 256-byte rounding) and it binds as a root SRV in Draw.
	common.upload_buffer_init(&fr.material_buffer, device, material_count, false)
}

// C++: ~FrameResource.
frame_resource_destroy :: proc(fr: ^Frame_Resource) {
	common.upload_buffer_destroy(&fr.material_buffer)
	common.upload_buffer_destroy(&fr.pass_cb)
	if fr.cmd_list_alloc != nil {fr.cmd_list_alloc->Release();fr.cmd_list_alloc = nil}
}
