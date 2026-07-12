// Chapter 3 (Transformations) as tests. Run: odin test odin_port/C3_TRANSFORMATIONS
//
// Chapter 3 has NO demo in the book's source — these tests exercise the DirectXMath
// functions the chapter covers, asserting against output captured from a small C++
// ground-truth program (XMMatrixRotationY, S*R*T composition, XMVector3TransformCoord/
// TransformNormal, XMMatrixRotationAxis, XMMatrixRotationRollPitchYaw; x64, 2026-07 —
// the same ground truth the Rust port uses).
//
// This is the chapter where ../d3d_math starts (as the porting guide planned): the
// scaling/rotation/translation builders typed from the book's printed forms. Because Mat4
// keeps the book's row-vector convention, every composition below reads EXACTLY as the
// book writes it — S * Ry * T, left-to-right. No reversal, no transposed literals.
// (The Rust port writes this same chain as T * Ry * S.)
//
// One approximation note: DXM's XMScalarSinCos is a polynomial approximation — its
// RotationY(π/4) has cos = 0.70710671 where core:math gives 0.70710677. Same category as
// chapter 1's XMVectorCos difference; hence tolerances even on "clean" rotation matrices.
package c3_transformations

import "core:math"
import "core:math/linalg"
import "core:testing"
import dm "../d3d_math"
import tu "../test_util"

// C++: XMMATRIX Ry = XMMatrixRotationY(XM_PIDIV4);
@(test)
rotation_y :: proc(t: ^testing.T) {
	ry := dm.rotation_y(math.PI / 4)
	// C++ output rows — ours verbatim (row-vector matrix, rows are rows):
	tu.expect_close(t, ry, dm.Mat4{
		0.70710671, 0, -0.70710677, 0,
		0,          1, 0,           0,
		0.70710677, 0, 0.70710671,  0,
		0,          0, 0,           1,
	}, 1e-6)
}

// The chapter's core lesson: composing scale → rotate → translate.
// C++: XMMATRIX M = S * Ry * T;   — and that is EXACTLY how it is written here.
@(test)
srt_composition :: proc(t: ^testing.T) {
	s := dm.scaling(0.5, 2, 1.5)
	ry := dm.rotation_y(math.PI / 4)
	tr := dm.translation(1, 2, 3)

	m := s * ry * tr // book order, left-to-right (rust_port writes: t * ry * s)

	// C++ output rows of M = S*Ry*T:
	tu.expect_close(t, m, dm.Mat4{
		0.35355335, 0, -0.35355338, 0,
		0,          2, 0,           0,
		1.0606601,  0, 1.0606601,   0,
		1,          2, 3,           1,
	}, 1e-6)

	// C++: XMVector3TransformCoord(p, M) = (2.4142134, 4, 3.7071071, 1)
	p := [3]f32{1, 1, 1}
	q := dm.transform_coord(p, m)
	tu.expect_close(t, q, [3]f32{2.4142134, 4, 3.7071071}, 1e-6)

	// C++: XMVector3TransformNormal(n, M) = (1.0606601, 0, 1.0606601, 0)
	// w = 0: the translation row contributes nothing.
	n := [3]f32{0, 0, 1}
	tu.expect_close(t, dm.transform_normal(n, m), [3]f32{1.0606601, 0, 1.0606601}, 1e-6)

	// The didactic negative: the REVERSED spelling is a different transform here
	// (in the Rust port this assertion points the other way).
	wrong := tr * ry * s
	testing.expect(t, dm.transform_coord(p, wrong) != q)
}

// C++: XMMATRIX Ra = XMMatrixRotationAxis(axis, 0.5f);
@(test)
rotation_about_arbitrary_axis :: proc(t: ^testing.T) {
	// d3d_math.rotation_axis requires the axis normalized (DXM's RotationAxis normalizes
	// internally; ours matches its RotationNormal variant).
	axis := linalg.normalize([3]f32{1, 2, 3})
	ra := dm.rotation_axis(axis, 0.5)
	// C++: TransformCoord(p, Ra) = (0.80191535, 1.2387755, 0.90684456, 1)
	q := dm.transform_coord([3]f32{1, 1, 1}, ra)
	tu.expect_close(t, q, [3]f32{0.80191535, 1.2387755, 0.90684456}, 1e-6)
}

// C++: XMMATRIX Rpy = XMMatrixRotationRollPitchYaw(0.3f, 0.7f, 1.1f);
//      (arguments: pitch = 0.3 about x, yaw = 0.7 about y, roll = 1.1 about z;
//       applied roll first, then pitch, then yaw)
@(test)
roll_pitch_yaw :: proc(t: ^testing.T) {
	rpy := dm.rotation_roll_pitch_yaw(0.3, 0.7, 1.1)

	// …which, in row-vector convention, is this left-to-right product (roll applied first):
	explicit := dm.rotation_z(1.1) * dm.rotation_x(0.3) * dm.rotation_y(0.7)
	tu.expect_close(t, rpy, explicit, 1e-6)

	// C++: TransformCoord(p, Rpy) = (0.53676397, 0.98921961, 1.3165594, 1)
	q := dm.transform_coord([3]f32{1, 1, 1}, rpy)
	tu.expect_close(t, q, [3]f32{0.53676397, 0.98921961, 1.3165594}, 1e-6)
}
