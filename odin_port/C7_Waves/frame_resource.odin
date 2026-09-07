// Port of `Demos/C7_Waves/FrameResource.h/.cpp` (Frank Luna) — like C7_Shapes' plus the
// per-frame dynamic wave vertex buffer.
package c7_waves

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

// C++: struct ColorVertex { XMFLOAT3 Pos; XMFLOAT4 Color; };  (lives in FrameResource.h
// here because the dynamic wave VB is typed on it.)
Color_Vertex :: struct {
	pos:   [3]f32,
	color: [4]f32,
}

// Stores the resources needed for the CPU to build the command lists
// for a frame.
Frame_Resource :: struct {
	// We cannot reset the allocator until the GPU is done processing the commands.
	// So each frame needs their own allocator.
	cmd_list_alloc: ^d3d12.ICommandAllocator,

	// We cannot update a buffer until the GPU is done processing the commands
	// that reference it.  So each frame needs their own buffers.
	pass_cb:        common.Upload_Buffer(Pass_Constants),

	// We cannot update a dynamic vertex buffer until the GPU is done processing
	// the commands that reference it.  So each frame needs their own.
	waves_vb:       common.Upload_Buffer(Color_Vertex),

	// Fence value to mark commands up to this fence point.  This lets us
	// check if these frame resources are still in use by the GPU.
	fence:          u64,
}

// C++: FrameResource(device, passCount, waveVertCount).
frame_resource_init :: proc(
	fr: ^Frame_Resource,
	device: ^d3d12.IDevice5,
	pass_count: u32,
	wave_vert_count: u32,
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
	common.upload_buffer_init(&fr.waves_vb, device, wave_vert_count, false)
}

// C++: ~FrameResource.
frame_resource_destroy :: proc(fr: ^Frame_Resource) {
	common.upload_buffer_destroy(&fr.waves_vb)
	common.upload_buffer_destroy(&fr.pass_cb)
	if fr.cmd_list_alloc != nil {fr.cmd_list_alloc->Release();fr.cmd_list_alloc = nil}
}
