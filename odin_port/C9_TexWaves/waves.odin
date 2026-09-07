// Port of `Demos/C9_TexWaves/Waves.h/.cpp` (Frank Luna) — identical to C7/C8's copies
// (the C++ duplicates the file per demo too). Performs the calculations for the wave
// simulation; after the update, the client must copy the current solution into vertex
// buffers for rendering. This file only does the calculations, it does not do any drawing.
//
// DELIBERATE DEVIATION: the C++ runs the two interior loops under
// concurrency::parallel_for (PPL). This port keeps them SERIAL — user decision 2026-07:
// multithreading waits until much later (no TSan on Windows to keep it honest). At
// 128x128 the serial update is a rounding error per frame.
package c9_texwaves

import "core:math/linalg"

Waves :: struct {
	num_rows: int,
	num_cols: int,

	vertex_count:   int,
	triangle_count: int,

	// Simulation constants we can precompute.
	k1: f32,
	k2: f32,
	k3: f32,

	time_step:    f32,
	spatial_step: f32,

	prev_solution: [][3]f32,
	curr_solution: [][3]f32,
	normals:       [][3]f32,
	tangent_x:     [][3]f32,

	t: f32, // C++: function-local static in Update()
}

// C++: Waves(m, n, dx, dt, speed, damping).
waves_init :: proc(w: ^Waves, m, n: int, dx, dt, speed, damping: f32) {
	w.num_rows = m
	w.num_cols = n

	w.vertex_count = m * n
	w.triangle_count = (m - 1) * (n - 1) * 2

	w.time_step = dt
	w.spatial_step = dx

	waves_set_constants(w, speed, damping)

	w.prev_solution = make([][3]f32, m * n)
	w.curr_solution = make([][3]f32, m * n)
	w.normals = make([][3]f32, m * n)
	w.tangent_x = make([][3]f32, m * n)

	// Generate grid vertices in system memory.

	half_width := f32(n - 1) * dx * 0.5
	half_depth := f32(m - 1) * dx * 0.5
	for i in 0 ..< m {
		z := half_depth - f32(i) * dx
		for j in 0 ..< n {
			x := -half_width + f32(j) * dx

			w.prev_solution[i * n + j] = {x, 0.0, z}
			w.curr_solution[i * n + j] = {x, 0.0, z}
			w.normals[i * n + j] = {0.0, 1.0, 0.0}
			w.tangent_x[i * n + j] = {1.0, 0.0, 0.0}
		}
	}
}

waves_destroy :: proc(w: ^Waves) {
	delete(w.prev_solution)
	delete(w.curr_solution)
	delete(w.normals)
	delete(w.tangent_x)
}

// C++: Waves::SetConstants(speed, damping) — called every frame from the UI sliders.
waves_set_constants :: proc(w: ^Waves, speed, damping: f32) {
	d := damping * w.time_step + 2.0
	e := (speed * speed) * (w.time_step * w.time_step) / (w.spatial_step * w.spatial_step)
	w.k1 = (damping * w.time_step - 2.0) / d
	w.k2 = (4.0 - 8.0 * e) / d
	w.k3 = (2.0 * e) / d
}

// C++: Waves::Update(dt).
waves_update :: proc(w: ^Waves, dt: f32) {
	// Accumulate time.
	w.t += dt

	// Only update the simulation at the specified time step.
	if w.t >= w.time_step {
		// Only update interior points; we use zero boundary conditions.
		// (C++: concurrency::parallel_for over i — serial here, see the file header.)
		for i in 1 ..< w.num_rows - 1 {
			for j in 1 ..< w.num_cols - 1 {
				// After this update we will be discarding the old previous
				// buffer, so overwrite that buffer with the new update.
				// Note how we can do this inplace (read/write to same element)
				// because we won't need prev_ij again and the assignment happens last.

				// Note j indexes x and i indexes z: h(x_j, z_i, t_k)
				// Moreover, our +z axis goes "down"; this is just to
				// keep consistent with our row indices going down.

				w.prev_solution[i * w.num_cols + j].y =
					w.k1 * w.prev_solution[i * w.num_cols + j].y +
					w.k2 * w.curr_solution[i * w.num_cols + j].y +
					w.k3 * (w.curr_solution[(i + 1) * w.num_cols + j].y +
							w.curr_solution[(i - 1) * w.num_cols + j].y +
							w.curr_solution[i * w.num_cols + j + 1].y +
							w.curr_solution[i * w.num_cols + j - 1].y)
			}
		}

		// We just overwrote the previous buffer with the new data, so
		// this data needs to become the current solution and the old
		// current solution becomes the new previous solution.
		w.prev_solution, w.curr_solution = w.curr_solution, w.prev_solution

		w.t = 0.0 // reset time

		//
		// Compute normals using finite difference scheme.
		//
		for i in 1 ..< w.num_rows - 1 {
			for j in 1 ..< w.num_cols - 1 {
				l := w.curr_solution[i * w.num_cols + j - 1].y
				r := w.curr_solution[i * w.num_cols + j + 1].y
				t := w.curr_solution[(i - 1) * w.num_cols + j].y
				b := w.curr_solution[(i + 1) * w.num_cols + j].y

				w.normals[i * w.num_cols + j] = linalg.normalize(
					[3]f32{-r + l, 2.0 * w.spatial_step, b - t},
				)
				w.tangent_x[i * w.num_cols + j] = linalg.normalize(
					[3]f32{2.0 * w.spatial_step, r - l, 0.0},
				)
			}
		}
	}
}

// C++: Waves::Disturb(i, j, magnitude).
waves_disturb :: proc(w: ^Waves, i, j: int, magnitude: f32) {
	// Don't disturb boundaries.
	assert(i > 1 && i < w.num_rows - 2)
	assert(j > 1 && j < w.num_cols - 2)

	half_mag := 0.5 * magnitude

	// Disturb the ijth vertex height and its neighbors.
	w.curr_solution[i * w.num_cols + j].y += magnitude
	w.curr_solution[i * w.num_cols + j + 1].y += half_mag
	w.curr_solution[i * w.num_cols + j - 1].y += half_mag
	w.curr_solution[(i + 1) * w.num_cols + j].y += half_mag
	w.curr_solution[(i - 1) * w.num_cols + j].y += half_mag
}
