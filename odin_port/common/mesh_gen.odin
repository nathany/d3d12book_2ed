// Port of `Common/MeshGen.h/.cpp` (Frank Luna) — procedurally generating the geometry of
// common mathematical objects. All triangles are generated "outward" facing.
//
// Memory: Mesh_Gen_Data owns two dynamic arrays; call mesh_gen_data_destroy on every
// value returned from a create_* proc (and on composite meshes) when done — the demos do
// this right after uploading to the GPU.
package common

import "core:math"
import "core:math/linalg"

Mesh_Gen_Vertex :: struct {
	position:  [3]f32,
	normal:    [3]f32,
	tangent_u: [3]f32,
	tex_c:     [2]f32,
}

Mesh_Gen_Data :: struct {
	vertices:  [dynamic]Mesh_Gen_Vertex,
	indices32: [dynamic]u32,
}

mesh_gen_data_destroy :: proc(data: ^Mesh_Gen_Data) {
	delete(data.vertices)
	delete(data.indices32)
}

// C++: MeshGenData::GetIndices16() — the demos index with u16 (their vertex counts allow
// it); caller deletes the returned slice.
get_indices16 :: proc(data: ^Mesh_Gen_Data, allocator := context.allocator) -> []u16 {
	indices16 := make([]u16, len(data.indices32), allocator)
	for index32, i in data.indices32 {
		indices16[i] = u16(index32)
	}
	return indices16
}

// C++: MeshGenData::AppendSubmesh — concatenate another mesh into this one, returning the
// submesh draw-args (offsets + bounds) for the appended region.
append_submesh :: proc(composite: ^Mesh_Gen_Data, mesh: ^Mesh_Gen_Data) -> Submesh_Geometry {
	vertex_offset := u32(len(composite.vertices))
	index_offset := u32(len(composite.indices32))

	v_min := [3]f32{+math.F32_MAX, +math.F32_MAX, +math.F32_MAX}
	v_max := [3]f32{-math.F32_MAX, -math.F32_MAX, -math.F32_MAX}

	for &v in mesh.vertices {
		v_min = linalg.min(v_min, v.position)
		v_max = linalg.max(v_max, v.position)
	}

	submesh := Submesh_Geometry {
		index_count          = u32(len(mesh.indices32)),
		start_index_location = index_offset,
		base_vertex_location = i32(vertex_offset),
		vertex_count         = u32(len(mesh.vertices)),
		bounds               = {center = 0.5 * (v_min + v_max), extents = 0.5 * (v_max - v_min)},
	}

	append(&composite.vertices, ..mesh.vertices[:])
	append(&composite.indices32, ..mesh.indices32[:])

	return submesh
}

// C++: MeshGen::CreateBox — a box centered at the origin, each face two triangles (24
// vertices so normals/tangents/uvs are per-face), optionally subdivided.
create_box :: proc(width, height, depth: f32, num_subdivisions: u32) -> Mesh_Gen_Data {
	mesh_data: Mesh_Gen_Data

	//
	// Create the vertices.
	//

	w2 := 0.5 * width
	h2 := 0.5 * height
	d2 := 0.5 * depth

	v := [24]Mesh_Gen_Vertex {
		// Fill in the front face vertex data.
		{{-w2, -h2, -d2}, {0, 0, -1}, {1, 0, 0}, {0, 1}},
		{{-w2, +h2, -d2}, {0, 0, -1}, {1, 0, 0}, {0, 0}},
		{{+w2, +h2, -d2}, {0, 0, -1}, {1, 0, 0}, {1, 0}},
		{{+w2, -h2, -d2}, {0, 0, -1}, {1, 0, 0}, {1, 1}},

		// Fill in the back face vertex data.
		{{-w2, -h2, +d2}, {0, 0, 1}, {-1, 0, 0}, {1, 1}},
		{{+w2, -h2, +d2}, {0, 0, 1}, {-1, 0, 0}, {0, 1}},
		{{+w2, +h2, +d2}, {0, 0, 1}, {-1, 0, 0}, {0, 0}},
		{{-w2, +h2, +d2}, {0, 0, 1}, {-1, 0, 0}, {1, 0}},

		// Fill in the top face vertex data.
		{{-w2, +h2, -d2}, {0, 1, 0}, {1, 0, 0}, {0, 1}},
		{{-w2, +h2, +d2}, {0, 1, 0}, {1, 0, 0}, {0, 0}},
		{{+w2, +h2, +d2}, {0, 1, 0}, {1, 0, 0}, {1, 0}},
		{{+w2, +h2, -d2}, {0, 1, 0}, {1, 0, 0}, {1, 1}},

		// Fill in the bottom face vertex data.
		{{-w2, -h2, -d2}, {0, -1, 0}, {-1, 0, 0}, {1, 1}},
		{{+w2, -h2, -d2}, {0, -1, 0}, {-1, 0, 0}, {0, 1}},
		{{+w2, -h2, +d2}, {0, -1, 0}, {-1, 0, 0}, {0, 0}},
		{{-w2, -h2, +d2}, {0, -1, 0}, {-1, 0, 0}, {1, 0}},

		// Fill in the left face vertex data.
		{{-w2, -h2, +d2}, {-1, 0, 0}, {0, 0, -1}, {0, 1}},
		{{-w2, +h2, +d2}, {-1, 0, 0}, {0, 0, -1}, {0, 0}},
		{{-w2, +h2, -d2}, {-1, 0, 0}, {0, 0, -1}, {1, 0}},
		{{-w2, -h2, -d2}, {-1, 0, 0}, {0, 0, -1}, {1, 1}},

		// Fill in the right face vertex data.
		{{+w2, -h2, -d2}, {1, 0, 0}, {0, 0, 1}, {0, 1}},
		{{+w2, +h2, -d2}, {1, 0, 0}, {0, 0, 1}, {0, 0}},
		{{+w2, +h2, +d2}, {1, 0, 0}, {0, 0, 1}, {1, 0}},
		{{+w2, -h2, +d2}, {1, 0, 0}, {0, 0, 1}, {1, 1}},
	}
	append(&mesh_data.vertices, ..v[:])

	//
	// Create the indices.
	//

	i := [36]u32 {
		0, 1, 2, 0, 2, 3, //       front face
		4, 5, 6, 4, 6, 7, //       back face
		8, 9, 10, 8, 10, 11, //    top face
		12, 13, 14, 12, 14, 15, // bottom face
		16, 17, 18, 16, 18, 19, // left face
		20, 21, 22, 20, 22, 23, // right face
	}
	append(&mesh_data.indices32, ..i[:])

	// Put a cap on the number of subdivisions.
	num_subdivisions := min(num_subdivisions, 6)

	for _ in 0 ..< num_subdivisions {
		subdivide(&mesh_data)
	}

	return mesh_data
}

// C++: MeshGen::CreateSphere — a sphere from slice/stack rings between two pole vertices.
create_sphere :: proc(radius: f32, slice_count, stack_count: u32) -> Mesh_Gen_Data {
	mesh_data: Mesh_Gen_Data

	//
	// Compute the vertices stating at the top pole and moving down the stacks.
	//

	// Poles: note that there will be texture coordinate distortion as there is
	// not a unique point on the texture map to assign to the pole when mapping
	// a rectangular texture onto a sphere.
	top_vertex := Mesh_Gen_Vertex{{0, +radius, 0}, {0, +1, 0}, {1, 0, 0}, {0, 0}}
	bottom_vertex := Mesh_Gen_Vertex{{0, -radius, 0}, {0, -1, 0}, {1, 0, 0}, {0, 1}}

	append(&mesh_data.vertices, top_vertex)

	phi_step := math.PI / f32(stack_count)
	theta_step := 2.0 * math.PI / f32(slice_count)

	// Compute vertices for each stack ring (do not count the poles as rings).
	for i in 1 ..= stack_count - 1 {
		phi := f32(i) * phi_step

		// Vertices of ring.
		for j in 0 ..= slice_count {
			theta := f32(j) * theta_step

			v: Mesh_Gen_Vertex

			// spherical to cartesian
			v.position.x = radius * math.sin(phi) * math.cos(theta)
			v.position.y = radius * math.cos(phi)
			v.position.z = radius * math.sin(phi) * math.sin(theta)

			// Partial derivative of P with respect to theta
			v.tangent_u.x = -radius * math.sin(phi) * math.sin(theta)
			v.tangent_u.y = 0.0
			v.tangent_u.z = +radius * math.sin(phi) * math.cos(theta)
			v.tangent_u = linalg.normalize(v.tangent_u)

			v.normal = linalg.normalize(v.position)

			v.tex_c.x = theta / (2 * math.PI)
			v.tex_c.y = phi / math.PI

			append(&mesh_data.vertices, v)
		}
	}

	append(&mesh_data.vertices, bottom_vertex)

	//
	// Compute indices for top stack.  The top stack was written first to the vertex buffer
	// and connects the top pole to the first ring.
	//

	for i in 1 ..= slice_count {
		append(&mesh_data.indices32, 0, i + 1, i)
	}

	//
	// Compute indices for inner stacks (not connected to poles).
	//

	// Offset the indices to the index of the first vertex in the first ring.
	// This is just skipping the top pole vertex.
	base_index: u32 = 1
	ring_vertex_count := slice_count + 1
	for i in 0 ..< stack_count - 2 {
		for j in 0 ..< slice_count {
			append(
				&mesh_data.indices32,
				base_index + i * ring_vertex_count + j,
				base_index + i * ring_vertex_count + j + 1,
				base_index + (i + 1) * ring_vertex_count + j,
			)
			append(
				&mesh_data.indices32,
				base_index + (i + 1) * ring_vertex_count + j,
				base_index + i * ring_vertex_count + j + 1,
				base_index + (i + 1) * ring_vertex_count + j + 1,
			)
		}
	}

	//
	// Compute indices for bottom stack.  The bottom stack was written last to the vertex
	// buffer and connects the bottom pole to the bottom ring.
	//

	// South pole vertex was added last.
	south_pole_index := u32(len(mesh_data.vertices)) - 1

	// Offset the indices to the index of the first vertex in the last ring.
	base_index = south_pole_index - ring_vertex_count

	for i in 0 ..< slice_count {
		append(&mesh_data.indices32, south_pole_index, base_index + i, base_index + i + 1)
	}

	return mesh_data
}

// C++: MeshGen::Subdivide — split every triangle into four via edge midpoints.
@(private = "file")
subdivide :: proc(mesh_data: ^Mesh_Gen_Data) {
	// Save a copy of the input geometry.
	input_copy: Mesh_Gen_Data
	append(&input_copy.vertices, ..mesh_data.vertices[:])
	append(&input_copy.indices32, ..mesh_data.indices32[:])
	defer mesh_gen_data_destroy(&input_copy)

	clear(&mesh_data.vertices)
	clear(&mesh_data.indices32)

	//       v1
	//       *
	//      / \
	//     /   \
	//  m0*-----*m1
	//   / \   / \
	//  /   \ /   \
	// *-----*-----*
	// v0    m2     v2

	num_tris := u32(len(input_copy.indices32) / 3)
	for i in 0 ..< num_tris {
		v0 := input_copy.vertices[input_copy.indices32[i * 3 + 0]]
		v1 := input_copy.vertices[input_copy.indices32[i * 3 + 1]]
		v2 := input_copy.vertices[input_copy.indices32[i * 3 + 2]]

		//
		// Generate the midpoints.
		//

		m0 := mid_point(v0, v1)
		m1 := mid_point(v1, v2)
		m2 := mid_point(v0, v2)

		//
		// Add new geometry.
		//

		append(&mesh_data.vertices, v0, v1, v2, m0, m1, m2) // 0..5

		append(&mesh_data.indices32, i * 6 + 0, i * 6 + 3, i * 6 + 5)
		append(&mesh_data.indices32, i * 6 + 3, i * 6 + 4, i * 6 + 5)
		append(&mesh_data.indices32, i * 6 + 5, i * 6 + 4, i * 6 + 2)
		append(&mesh_data.indices32, i * 6 + 3, i * 6 + 1, i * 6 + 4)
	}
}

// C++: MeshGen::MidPoint — midpoints of all the attributes. Vectors need to be
// normalized since linear interpolating can make them not unit length.
@(private = "file")
mid_point :: proc(v0, v1: Mesh_Gen_Vertex) -> Mesh_Gen_Vertex {
	return {
		position = 0.5 * (v0.position + v1.position),
		normal = linalg.normalize(0.5 * (v0.normal + v1.normal)),
		tangent_u = linalg.normalize(0.5 * (v0.tangent_u + v1.tangent_u)),
		tex_c = 0.5 * (v0.tex_c + v1.tex_c),
	}
}

// C++: MeshGen::CreateGeosphere — tessellated icosahedron projected onto the sphere.
create_geosphere :: proc(radius: f32, num_subdivisions: u32) -> Mesh_Gen_Data {
	mesh_data: Mesh_Gen_Data

	// Put a cap on the number of subdivisions.
	num_subdivisions := min(num_subdivisions, 6)

	// Approximate a sphere by tessellating an icosahedron.

	X :: 0.525731
	Z :: 0.850651

	pos := [12][3]f32 {
		{-X, 0, Z}, {X, 0, Z},
		{-X, 0, -Z}, {X, 0, -Z},
		{0, Z, X}, {0, Z, -X},
		{0, -Z, X}, {0, -Z, -X},
		{Z, X, 0}, {-Z, X, 0},
		{Z, -X, 0}, {-Z, -X, 0},
	}

	k := [60]u32 {
		1, 4, 0, 4, 9, 0, 4, 5, 9, 8, 5, 4, 1, 8, 4,
		1, 10, 8, 10, 3, 8, 8, 3, 5, 3, 2, 5, 3, 7, 2,
		3, 10, 7, 10, 6, 7, 6, 11, 7, 6, 0, 11, 6, 1, 0,
		10, 1, 6, 11, 0, 9, 2, 11, 9, 5, 2, 9, 11, 2, 7,
	}

	resize(&mesh_data.vertices, 12)
	append(&mesh_data.indices32, ..k[:])

	for i in 0 ..< 12 {
		mesh_data.vertices[i].position = pos[i]
	}

	for _ in 0 ..< num_subdivisions {
		subdivide(&mesh_data)
	}

	// Project vertices onto sphere and scale.
	for &v in mesh_data.vertices {
		// Project onto unit sphere, then onto sphere.
		n := linalg.normalize(v.position)
		v.position = radius * n
		v.normal = n

		// Derive texture coordinates from spherical coordinates.
		theta := math.atan2(v.position.z, v.position.x)

		// Put in [0, 2pi].
		if theta < 0.0 {
			theta += 2 * math.PI
		}

		phi := math.acos(v.position.y / radius)

		v.tex_c.x = theta / (2 * math.PI)
		v.tex_c.y = phi / math.PI

		// Partial derivative of P with respect to theta
		v.tangent_u.x = -radius * math.sin(phi) * math.sin(theta)
		v.tangent_u.y = 0.0
		v.tangent_u.z = +radius * math.sin(phi) * math.cos(theta)
		v.tangent_u = linalg.normalize(v.tangent_u)
	}

	return mesh_data
}

// C++: MeshGen::CreateCylinder — stacked rings from bottom to top plus two caps; the
// bottom and top radius can differ to form cone shapes.
create_cylinder :: proc(
	bottom_radius, top_radius, height: f32,
	slice_count, stack_count: u32,
) -> Mesh_Gen_Data {
	mesh_data: Mesh_Gen_Data

	//
	// Build Stacks.
	//

	stack_height := height / f32(stack_count)

	// Amount to increment radius as we move up each stack level from bottom to top.
	radius_step := (top_radius - bottom_radius) / f32(stack_count)

	ring_count := stack_count + 1

	// Compute vertices for each stack ring starting at the bottom and moving up.
	for i in 0 ..< ring_count {
		y := -0.5 * height + f32(i) * stack_height
		r := bottom_radius + f32(i) * radius_step

		// vertices of ring
		d_theta := 2.0 * math.PI / f32(slice_count)
		for j in 0 ..= slice_count {
			vertex: Mesh_Gen_Vertex

			c := math.cos(f32(j) * d_theta)
			s := math.sin(f32(j) * d_theta)

			vertex.position = {r * c, y, r * s}

			vertex.tex_c.x = f32(j) / f32(slice_count)
			vertex.tex_c.y = 1.0 - f32(i) / f32(stack_count)

			// (See the C++ for the parameterization derivation.) This is unit length.
			vertex.tangent_u = {-s, 0.0, c}

			dr := bottom_radius - top_radius
			bitangent := [3]f32{dr * c, -height, dr * s}

			vertex.normal = linalg.normalize(linalg.cross(vertex.tangent_u, bitangent))

			append(&mesh_data.vertices, vertex)
		}
	}

	// Add one because we duplicate the first and last vertex per ring
	// since the texture coordinates are different.
	ring_vertex_count := slice_count + 1

	// Compute indices for each stack.
	for i in 0 ..< stack_count {
		for j in 0 ..< slice_count {
			append(
				&mesh_data.indices32,
				i * ring_vertex_count + j,
				(i + 1) * ring_vertex_count + j,
				(i + 1) * ring_vertex_count + j + 1,
			)
			append(
				&mesh_data.indices32,
				i * ring_vertex_count + j,
				(i + 1) * ring_vertex_count + j + 1,
				i * ring_vertex_count + j + 1,
			)
		}
	}

	build_cylinder_top_cap(top_radius, height, slice_count, &mesh_data)
	build_cylinder_bottom_cap(bottom_radius, height, slice_count, &mesh_data)

	return mesh_data
}

// C++: MeshGen::BuildCylinderTopCap.
@(private = "file")
build_cylinder_top_cap :: proc(
	top_radius, height: f32,
	slice_count: u32,
	mesh_data: ^Mesh_Gen_Data,
) {
	base_index := u32(len(mesh_data.vertices))

	y := 0.5 * height
	d_theta := 2.0 * math.PI / f32(slice_count)

	// Duplicate cap ring vertices because the texture coordinates and normals differ.
	for i in 0 ..= slice_count {
		x := top_radius * math.cos(f32(i) * d_theta)
		z := top_radius * math.sin(f32(i) * d_theta)

		// Scale down by the height to try and make top cap texture coord area
		// proportional to base.
		u := x / height + 0.5
		v := z / height + 0.5

		append(&mesh_data.vertices, Mesh_Gen_Vertex{{x, y, z}, {0, 1, 0}, {1, 0, 0}, {u, v}})
	}

	// Cap center vertex.
	append(&mesh_data.vertices, Mesh_Gen_Vertex{{0, y, 0}, {0, 1, 0}, {1, 0, 0}, {0.5, 0.5}})

	// Index of center vertex.
	center_index := u32(len(mesh_data.vertices)) - 1

	for i in 0 ..< slice_count {
		append(&mesh_data.indices32, center_index, base_index + i + 1, base_index + i)
	}
}

// C++: MeshGen::BuildCylinderBottomCap.
@(private = "file")
build_cylinder_bottom_cap :: proc(
	bottom_radius, height: f32,
	slice_count: u32,
	mesh_data: ^Mesh_Gen_Data,
) {
	base_index := u32(len(mesh_data.vertices))
	y := -0.5 * height

	// vertices of ring
	d_theta := 2.0 * math.PI / f32(slice_count)
	for i in 0 ..= slice_count {
		x := bottom_radius * math.cos(f32(i) * d_theta)
		z := bottom_radius * math.sin(f32(i) * d_theta)

		u := x / height + 0.5
		v := z / height + 0.5

		append(&mesh_data.vertices, Mesh_Gen_Vertex{{x, y, z}, {0, -1, 0}, {1, 0, 0}, {u, v}})
	}

	// Cap center vertex.
	append(&mesh_data.vertices, Mesh_Gen_Vertex{{0, y, 0}, {0, -1, 0}, {1, 0, 0}, {0.5, 0.5}})

	// Cache the index of center vertex.
	center_index := u32(len(mesh_data.vertices)) - 1

	for i in 0 ..< slice_count {
		append(&mesh_data.indices32, center_index, base_index + i, base_index + i + 1)
	}
}

// C++: MeshGen::CreateGrid — an m x n grid of vertices in the xz-plane.
create_grid :: proc(width, depth: f32, m, n: u32) -> Mesh_Gen_Data {
	mesh_data: Mesh_Gen_Data

	vertex_count := m * n
	face_count := (m - 1) * (n - 1) * 2

	//
	// Create the vertices.
	//

	half_width := 0.5 * width
	half_depth := 0.5 * depth

	dx := width / f32(n - 1)
	dz := depth / f32(m - 1)

	du := 1.0 / f32(n - 1)
	dv := 1.0 / f32(m - 1)

	resize(&mesh_data.vertices, int(vertex_count))
	for i in 0 ..< m {
		z := half_depth - f32(i) * dz
		for j in 0 ..< n {
			x := -half_width + f32(j) * dx

			mesh_data.vertices[i * n + j] = {
				position  = {x, 0.0, z},
				normal    = {0, 1, 0},
				tangent_u = {1, 0, 0},
				// Stretch texture over grid.
				tex_c     = {f32(j) * du, f32(i) * dv},
			}
		}
	}

	//
	// Create the indices.
	//

	resize(&mesh_data.indices32, int(face_count * 3)) // 3 indices per face

	// Iterate over each quad and compute indices.
	k: u32 = 0
	for i in 0 ..< m - 1 {
		for j in 0 ..< n - 1 {
			mesh_data.indices32[k] = i * n + j
			mesh_data.indices32[k + 1] = i * n + j + 1
			mesh_data.indices32[k + 2] = (i + 1) * n + j

			mesh_data.indices32[k + 3] = (i + 1) * n + j
			mesh_data.indices32[k + 4] = i * n + j + 1
			mesh_data.indices32[k + 5] = (i + 1) * n + j + 1

			k += 6 // next quad
		}
	}

	return mesh_data
}

// C++: MeshGen::CreateQuad — a screen-aligned quad in NDC space (postprocessing/debug).
create_quad :: proc(x, y, w, h, depth: f32) -> Mesh_Gen_Data {
	mesh_data: Mesh_Gen_Data

	// Position coordinates specified in NDC space.
	append(
		&mesh_data.vertices,
		Mesh_Gen_Vertex{{x, y - h, depth}, {0, 0, -1}, {1, 0, 0}, {0, 1}},
		Mesh_Gen_Vertex{{x, y, depth}, {0, 0, -1}, {1, 0, 0}, {0, 0}},
		Mesh_Gen_Vertex{{x + w, y, depth}, {0, 0, -1}, {1, 0, 0}, {1, 0}},
		Mesh_Gen_Vertex{{x + w, y - h, depth}, {0, 0, -1}, {1, 0, 0}, {1, 1}},
	)

	append(&mesh_data.indices32, 0, 1, 2, 0, 2, 3)

	return mesh_data
}
