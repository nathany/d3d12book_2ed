// Port of the geometry-building half of `Common/d3dUtil.h/.cpp` (Frank Luna), which
// chapter 8 promotes into Common because every demo from here on shares it: the standard
// vertex type (`ModelVertex`), the CPU-side `Material`, the composite shape mesh, and the
// skull model loader.
package common

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../d3d_math"

// C++: struct ModelVertex — matches the standard input layout (POSITION, NORMAL,
// TEXCOORD, TANGENT at offsets 0/12/24/32, stride 44).
Model_Vertex :: struct {
	pos:       [3]f32,
	normal:    [3]f32,
	tex_c:     [2]f32,
	tangent_u: [3]f32,
}

#assert(size_of(Model_Vertex) == 44)

// C++: struct Material (d3dUtil.h) — simple struct to represent a material for our demos.
// Only the members the chapters so far read are ported; the ray-tracing fields arrive
// with their chapters.
Material :: struct {
	// Unique material name for lookup.
	name:                      string,

	// Index into material buffer.
	mat_index:                 i32,

	// For bindless texturing (ch 9+): heap indices of this material's textures.
	albedo_bindless_index:     i32,
	normal_bindless_index:     i32,
	gloss_height_ao_bindless_index: i32,

	// Dirty flag indicating the material has changed and we need to update the buffer.
	// Because we have a material buffer for each FrameResource, we have to apply the
	// update to each FrameResource.  Thus, when we modify a material we should set
	// num_frames_dirty = NUM_FRAME_RESOURCES so that each frame resource gets the update.
	num_frames_dirty:          i32,

	// Material constant buffer data used for shading.
	diffuse_albedo:            [4]f32,
	fresnel_r0:                [3]f32,
	roughness:                 f32,
	displacement_scale:        f32,
	mat_transform:             d3d_math.Mat4,
}

// C++: d3dUtil::BuildShapeGeometry — box/grid/sphere/cylinder/quad concatenated into one
// vertex/index buffer pair, now with the full ModelVertex (the chapter 7 demos extracted
// only position+color). Ported for the default useIndex32=false; the 32-bit path arrives
// with the chapter that needs it.
build_shape_geometry :: proc(upload_batch: ^Resource_Upload_Batch) -> ^Mesh_Geometry {
	box := create_box(1.0, 1.0, 1.0, 3)
	grid := create_grid(20.0, 30.0, 30, 20)
	sphere := create_sphere(0.5, 20, 20)
	cylinder := create_cylinder(0.5, 0.3, 3.0, 20, 20)
	quad := create_quad(0.0, 0.0, 1.0, 1.0, 0.0)
	defer {
		mesh_gen_data_destroy(&box)
		mesh_gen_data_destroy(&grid)
		mesh_gen_data_destroy(&sphere)
		mesh_gen_data_destroy(&cylinder)
		mesh_gen_data_destroy(&quad)
	}

	//
	// We are concatenating all the geometry into one big vertex/index buffer.  So
	// define the regions in the buffer each submesh covers.
	//
	composite_mesh: Mesh_Gen_Data
	defer mesh_gen_data_destroy(&composite_mesh)
	box_submesh := append_submesh(&composite_mesh, &box)
	grid_submesh := append_submesh(&composite_mesh, &grid)
	sphere_submesh := append_submesh(&composite_mesh, &sphere)
	cylinder_submesh := append_submesh(&composite_mesh, &cylinder)
	quad_submesh := append_submesh(&composite_mesh, &quad)

	// Extract the vertex elements we are interested into our vertex buffer.
	vertices := make([]Model_Vertex, len(composite_mesh.vertices))
	defer delete(vertices)
	for &v, i in vertices {
		v.pos = composite_mesh.vertices[i].position
		v.normal = composite_mesh.vertices[i].normal
		v.tex_c = composite_mesh.vertices[i].tex_c
		v.tangent_u = composite_mesh.vertices[i].tangent_u
	}

	indices := get_indices16(&composite_mesh)
	defer delete(indices)

	vb_byte_size := u32(len(vertices) * size_of(Model_Vertex))
	ib_byte_size := u32(len(indices) * size_of(u16))

	geo := new(Mesh_Geometry)
	geo.name = "shapeGeo"

	geo.vertex_buffer_cpu = slice.clone(slice.to_bytes(vertices))
	geo.index_buffer_cpu = slice.clone(slice.to_bytes(indices))

	create_static_buffer(
		upload_batch,
		raw_data(vertices),
		len(vertices),
		size_of(Model_Vertex),
		{.VERTEX_AND_CONSTANT_BUFFER},
		&geo.vertex_buffer_gpu,
	)

	create_static_buffer(
		upload_batch,
		raw_data(indices),
		len(indices),
		size_of(u16),
		{.INDEX_BUFFER},
		&geo.index_buffer_gpu,
	)

	geo.vertex_byte_stride = size_of(Model_Vertex)
	geo.vertex_buffer_byte_size = vb_byte_size
	geo.index_format = .R16_UINT
	geo.index_buffer_byte_size = ib_byte_size

	geo.draw_args["box"] = box_submesh
	geo.draw_args["grid"] = grid_submesh
	geo.draw_args["sphere"] = sphere_submesh
	geo.draw_args["cylinder"] = cylinder_submesh
	geo.draw_args["quad"] = quad_submesh

	return geo
}

// The C++ reads skull.txt through istream `>>`, which tokenizes on whitespace; these two
// helpers are that operator, fatal on malformed input (the C++ would silently zero-fill —
// failing loudly beats rendering a subtly wrong mesh).
@(private = "file")
next_token :: proc(it: ^string, what: string) -> string {
	tok, ok := strings.fields_iterator(it)
	if !ok {
		report_error(fmt.tprintf("Models/skull.txt: unexpected end of file reading %s", what))
		os.exit(1)
	}
	return tok
}

@(private = "file")
next_f32 :: proc(it: ^string, what: string) -> f32 {
	tok := next_token(it, what)
	value, ok := strconv.parse_f32(tok)
	if !ok {
		report_error(fmt.tprintf("Models/skull.txt: expected number for %s, got %q", what, tok))
		os.exit(1)
	}
	return value
}

@(private = "file")
next_int :: proc(it: ^string, what: string) -> int {
	tok := next_token(it, what)
	value, ok := strconv.parse_int(tok)
	if !ok {
		report_error(fmt.tprintf("Models/skull.txt: expected integer for %s, got %q", what, tok))
		os.exit(1)
	}
	return value
}

// C++: d3dUtil::BuildSkullGeometry — loads Models/skull.txt (raw text: vertex count,
// triangle count, then "pos normal" lines and index triples), generating tangents and
// spherical-projection texture coordinates the file doesn't carry.
build_skull_geometry :: proc(upload_batch: ^Resource_Upload_Batch) -> ^Mesh_Geometry {
	data, err := os.read_entire_file("Models/skull.txt", context.allocator)
	if err != nil {
		// C++: MessageBox + return nullptr (and the demo crashes on the missing geometry
		// soon after); we exit up front instead.
		report_error("Models/skull.txt not found.")
		os.exit(1)
	}
	defer delete(data)

	it := string(data)

	_ = next_token(&it, "header") // "VertexCount:"
	vcount := next_int(&it, "vertex count")
	_ = next_token(&it, "header") // "TriangleCount:"
	tcount := next_int(&it, "triangle count")
	for _ in 0 ..< 4 { 	// C++: fin >> ignore x4 — "VertexList (pos, normal) {"
		_ = next_token(&it, "header")
	}

	v_min := [3]f32{max(f32), max(f32), max(f32)}
	v_max := [3]f32{min(f32), min(f32), min(f32)}

	vertices := make([]Model_Vertex, vcount)
	defer delete(vertices)
	for &v in vertices {
		v.pos = {next_f32(&it, "position"), next_f32(&it, "position"), next_f32(&it, "position")}
		v.normal = {next_f32(&it, "normal"), next_f32(&it, "normal"), next_f32(&it, "normal")}

		// Project point onto unit sphere and generate spherical texture coordinates.
		sphere_pos := linalg.normalize(v.pos)

		// Generate a tangent vector so normal mapping works.  We aren't applying
		// a texture map to the skull, so we just need any tangent vector so that
		// the math works out to give us the original interpolated vertex normal.
		up := [3]f32{0.0, 1.0, 0.0}
		if abs(linalg.dot(v.normal, up)) < 1.0 - 0.001 {
			v.tangent_u = linalg.normalize(linalg.cross(up, v.normal))
		} else {
			up = {0.0, 0.0, 1.0}
			v.tangent_u = linalg.normalize(linalg.cross(v.normal, up))
		}

		// The skull mesh does not have defined texture coordinates, but
		// we can auto generate some. We generate sphereical projection
		// texture coordinates by projecting the vertices onto the unit
		// sphere. Because the skull is not a sphere, there will be some
		// distortion from this transformation, but it gives reasonable
		// texture coordinates when we have none.

		theta := math.atan2(sphere_pos.z, sphere_pos.x)

		// Put in [0, 2pi].
		if theta < 0.0 {
			theta += 2 * math.PI
		}

		phi := math.acos(sphere_pos.y)

		v.tex_c = {theta / (2.0 * math.PI), phi / math.PI}

		v_min = linalg.min(v_min, v.pos)
		v_max = linalg.max(v_max, v.pos)
	}

	bounds := Bounding_Box {
		center  = 0.5 * (v_min + v_max),
		extents = 0.5 * (v_max - v_min),
	}

	for _ in 0 ..< 3 { 	// C++: fin >> ignore x3 — "} TriangleList {"
		_ = next_token(&it, "header")
	}

	indices := make([]i32, 3 * tcount)
	defer delete(indices)
	for &index in indices {
		index = i32(next_int(&it, "index"))
	}

	vb_byte_size := u32(len(vertices) * size_of(Model_Vertex))
	ib_byte_size := u32(len(indices) * size_of(i32))

	geo := new(Mesh_Geometry)
	geo.name = "skullGeo"

	geo.vertex_buffer_cpu = slice.clone(slice.to_bytes(vertices))
	geo.index_buffer_cpu = slice.clone(slice.to_bytes(indices))

	create_static_buffer(
		upload_batch,
		raw_data(vertices),
		len(vertices),
		size_of(Model_Vertex),
		{.VERTEX_AND_CONSTANT_BUFFER},
		&geo.vertex_buffer_gpu,
	)

	create_static_buffer(
		upload_batch,
		raw_data(indices),
		len(indices),
		size_of(i32),
		{.INDEX_BUFFER},
		&geo.index_buffer_gpu,
	)

	geo.vertex_byte_stride = size_of(Model_Vertex)
	geo.vertex_buffer_byte_size = vb_byte_size
	geo.index_format = .R32_UINT
	geo.index_buffer_byte_size = ib_byte_size

	geo.draw_args["skull"] = Submesh_Geometry {
		index_count          = u32(len(indices)),
		start_index_location = 0,
		base_vertex_location = 0,
		vertex_count         = u32(len(vertices)),
		bounds               = bounds,
	}

	return geo
}
