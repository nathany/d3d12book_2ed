// Port of `Demos/C7_Shapes/FrameResource.h/.cpp` (Frank Luna).
package c7_shapes

import d3d12 "vendor:directx/d3d12"
import common "../common"
import "../d3d_math"

// C++: struct ObjectConstants { XMFLOAT4X4 World; };
Object_Constants :: struct {
	world: d3d_math.Mat4,
}

// C++: struct PassConstants { XMFLOAT4X4 ViewProj; };
Pass_Constants :: struct {
	view_proj: d3d_math.Mat4,
}

// Stores the resources needed for the CPU to build the command lists
// for a frame. The contents here will vary from app to app based on
// the needed resources.
Frame_Resource :: struct {
	// We cannot reset the allocator until the GPU is done processing the commands.
	// So each frame needs their own allocator.
	cmd_list_alloc: ^d3d12.ICommandAllocator,

	// We cannot update a buffer until the GPU is done processing the commands
	// that reference it.  So each frame needs their own buffers.
	pass_cb:        common.Upload_Buffer(Pass_Constants),

	// Fence value to mark commands up to this fence point.  This lets us
	// check if these frame resources are still in use by the GPU.
	fence:          u64,
}

// C++: FrameResource(device, passCount).
frame_resource_init :: proc(fr: ^Frame_Resource, device: ^d3d12.IDevice5, pass_count: u32) {
	common.hr_panic(
		device->CreateCommandAllocator(
			.DIRECT,
			d3d12.ICommandAllocator_UUID,
			common.ptr(&fr.cmd_list_alloc),
		),
		"CreateCommandAllocator(FrameResource)",
	)

	common.upload_buffer_init(&fr.pass_cb, device, pass_count, true)
}

// C++: ~FrameResource (the ComPtr/unique_ptr releases).
frame_resource_destroy :: proc(fr: ^Frame_Resource) {
	common.upload_buffer_destroy(&fr.pass_cb)
	if fr.cmd_list_alloc != nil {fr.cmd_list_alloc->Release();fr.cmd_list_alloc = nil}
}
