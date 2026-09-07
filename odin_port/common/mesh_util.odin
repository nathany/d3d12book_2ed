// Port of `Common/MeshUtil.h` (Frank Luna) — SubmeshGeometry/MeshGeometry, the book's
// "many submeshes packed into one vertex/index buffer pair" bookkeeping.
package common

import d3d12 "vendor:directx/d3d12"
import dxgi "vendor:directx/dxgi"

// C++: DirectX::BoundingBox (DirectXCollision.h) — just the data for now; the
// intersection tests arrive with the chapters that use them (picking, culling).
Bounding_Box :: struct {
	center:  [3]f32,
	extents: [3]f32, // half-widths along each axis
}

Submesh_Geometry :: struct {
	index_count:          u32,
	start_index_location: u32,
	base_vertex_location: i32,
	vertex_count:         u32,

	// Bounding box of the geometry defined by this submesh.
	// This is used in later chapters of the book.
	bounds:               Bounding_Box,
}

Mesh_Geometry :: struct {
	// Give it a name so we can look it up by name.
	name:                    string,

	// System memory copies.  Use byte blobs because the vertex/index format can be
	// generic.  It is up to the client to cast appropriately.
	vertex_buffer_cpu:       []byte,
	index_buffer_cpu:        []byte,

	vertex_buffer_gpu:       ^d3d12.IResource,
	index_buffer_gpu:        ^d3d12.IResource,

	// Data about the buffers.
	vertex_byte_stride:      u32,
	vertex_buffer_byte_size: u32,
	index_format:            dxgi.FORMAT, // C++ defaults to R16_UINT; demos set it
	index_buffer_byte_size:  u32,

	// A MeshGeometry may store multiple geometries in one vertex/index buffer.
	// Use this container to define the Submesh geometries so we can draw
	// the Submeshes individually.
	draw_args:               map[string]Submesh_Geometry,
}

// C++: MeshGeometry::VertexBufferView().
vertex_buffer_view :: proc(geo: ^Mesh_Geometry) -> d3d12.VERTEX_BUFFER_VIEW {
	return {
		BufferLocation = geo.vertex_buffer_gpu->GetGPUVirtualAddress(),
		StrideInBytes  = geo.vertex_byte_stride,
		SizeInBytes    = geo.vertex_buffer_byte_size,
	}
}

// C++: MeshGeometry::IndexBufferView().
index_buffer_view :: proc(geo: ^Mesh_Geometry) -> d3d12.INDEX_BUFFER_VIEW {
	return {
		BufferLocation = geo.index_buffer_gpu->GetGPUVirtualAddress(),
		Format         = geo.index_format,
		SizeInBytes    = geo.index_buffer_byte_size,
	}
}

// C++: ~MeshGeometry (ComPtr releases) + the vector/map destructors.
mesh_geometry_destroy :: proc(geo: ^Mesh_Geometry) {
	if geo.vertex_buffer_gpu != nil {geo.vertex_buffer_gpu->Release();geo.vertex_buffer_gpu = nil}
	if geo.index_buffer_gpu != nil {geo.index_buffer_gpu->Release();geo.index_buffer_gpu = nil}
	delete(geo.vertex_buffer_cpu)
	delete(geo.index_buffer_cpu)
	delete(geo.draw_args)
}
