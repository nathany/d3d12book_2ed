// Test port of `Demos/C2_XMMATRIX/xmmatrix.cpp` — chapter 2's console demo.
// Run: odin test odin_port/C2_XMMATRIX
//
// DirectXMath → Odin, the chapter 2 differences (matrices begin here):
//
//  1. NO convention flip. d3d_math.Mat4 is #row_major matrix[4,4]f32 with the book's
//     row-vector convention — matrix literals are typed exactly as the C++ lists them,
//     `A * B` stays `A * B`, and the C++ demo's printed rows are our rows. (Contrast with
//     rust_port, where glam's column-vector convention transposes every literal and
//     reverses every product.)
//  2. XMMATRIX and XMFLOAT4X4 both collapse into Mat4 — no load/store split, and #row_major
//     makes it byte-identical to XMFLOAT4X4.
//  3. Convention-agnostic ops are unchanged: transpose (builtin), linalg.determinant
//     (a plain f32 — DXM splats it across a vector), linalg.inverse (no determinant
//     out-param; the book always passes A's own determinant, computed internally).
//
// Expected values are the C++ demo's actual output (x64, 2026-07); every number in this
// demo is exactly representable, but inverse goes through adjugate/determinant arithmetic,
// so it gets a small tolerance rather than exact equality.
package c2_xmmatrix

import "core:math/linalg"
import "core:testing"
import dm "../d3d_math"
import tu "../test_util"

@(test)
xmmatrix :: proc(t: ^testing.T) {
	// C++: XMMATRIX A(1.0f, 0.0f, 0.0f, 0.0f,
	//                 0.0f, 2.0f, 0.0f, 0.0f,
	//                 0.0f, 0.0f, 4.0f, 0.0f,
	//                 1.0f, 2.0f, 3.0f, 1.0f);
	// Same 16 literals, same positions — Odin matrix literals are written row-major in
	// source, and Mat4 keeps the book's convention, so this IS the book's matrix.
	a := dm.Mat4{
		1, 0, 0, 0,
		0, 2, 0, 0,
		0, 0, 4, 0,
		1, 2, 3, 1,
	}
	// Semantically, A scales by (1,2,4) then translates by (1,2,3) — and unlike the Rust
	// port, the composition reads in BOOK ORDER (left-to-right, scale first):
	tu.expect_close(t, a, dm.scaling(1, 2, 4) * dm.translation(1, 2, 3), 0)

	// C++: XMMATRIX B = XMMatrixIdentity();
	b := dm.MAT4_IDENTITY

	// C++: XMMATRIX C = A * B;   — same spelling here (row-vector: apply A, then B)
	c := a * b
	tu.expect_close(t, c, a, 0)

	// C++: XMMATRIX D = XMMatrixTranspose(A);
	d := linalg.transpose(a)
	// C++ output rows of D (translation moved into the 4th column) — ours verbatim:
	tu.expect_close(t, d, dm.Mat4{
		1, 0, 0, 1,
		0, 2, 0, 2,
		0, 0, 4, 3,
		0, 0, 0, 1,
	}, 0)

	// C++: XMVECTOR det = XMMatrixDeterminant(A);   — splatted (8, 8, 8, 8)
	// linalg: a plain f32. (1 · 2 · 4 · 1 = 8; the translation doesn't affect it.)
	det := linalg.determinant(a)
	testing.expect_value(t, det, 8)

	// C++: XMMATRIX E = XMMatrixInverse(&det, A);
	e := linalg.inverse(a)
	// C++ output rows of E: undo the scale (1, 1/2, 1/4), then the translation:
	tu.expect_close(t, e, dm.Mat4{
		1, 0, 0, 0,
		0, 0.5, 0, 0,
		0, 0, 0.25, 0,
		-1, -1, -0.75, 1,
	}, 1e-6)

	// C++: XMMATRIX F = A * E;   — identity (same spelling again)
	f := a * e
	tu.expect_close(t, f, dm.MAT4_IDENTITY, 1e-6)
}
