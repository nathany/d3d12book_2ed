// Test port of `Demos/C1_XMVECTOR/xmvec3.cpp` (the variant left active in the C++ project).
// Run: odin test odin_port/C1_XMVECTOR
//
// Expected values are the C++ demo's actual output, e.g.
// `d = u / ||u|| = (0.267261, 0.534522, 0.801784)` — rounded by cout to 6 significant
// digits, hence the tolerances on the non-exact asserts.
//
// DirectXMath → Odin, the chapter 1 differences:
//
//  1. No load/store split: XMVECTOR (SIMD register) vs XMFLOAT3 (storage) and every
//     XMLoadFloat3/XMStoreFloat3 pair collapse into a plain [3]f32 — Odin's fixed arrays
//     are first-class math types (component-wise operators, swizzles).
//  2. 3D vectors are actually 3D: XMVECTOR is always 4 lanes — the C++ sets w = 0 and
//     ignores it; [3]f32 simply has no w.
//  3. Scalar results are scalars: XMVector3Length/XMVector3Dot return the result splatted
//     across all four lanes (extracted with XMVectorGetX); linalg.length/dot return f32.
//  4. Operators are the same: u + v, u - v, 10*u port verbatim.
//  5. XMVector3ComponentsFromNormal → linalg.projection + subtraction (same formulas:
//     proj = n·dot(w,n), perp = w − proj; n must be unit length).
//  6. XMVector3Equal → `==` (exact component compare). XMVector3AngleBetweenVectors has no
//     linalg equivalent — computed from acos(dot/(|a||b|)), which is all DXM does.
//  7. XMVerifyCPUSupport — deleted.
//
// (Matrix conventions start at chapter 2 — see ../d3d_math and the porting guide. Unlike
// the Rust/glam port, Odin keeps the book's row-vector convention.)
package c1_xmvector

import "core:math"
import "core:math/linalg"
import "core:testing"
import tu "../test_util"

@(test)
xmvec3 :: proc(t: ^testing.T) {
	// C++: XMVECTOR n = XMVectorSet(1.0f, 0.0f, 0.0f, 0.0f);
	//      XMVECTOR u = XMVectorSet(1.0f, 2.0f, 3.0f, 0.0f);
	//      XMVECTOR v = XMVectorSet(-2.0f, 1.0f, -3.0f, 0.0f);
	//      XMVECTOR w = XMVectorSet(0.707f, 0.707f, 0.0f, 0.0f);
	n := [3]f32{1, 0, 0}
	u := [3]f32{1, 2, 3}
	v := [3]f32{-2, 1, -3}
	w := [3]f32{0.707, 0.707, 0}

	// Vector addition: C++: XMVECTOR a = u + v;
	a := u + v
	testing.expect_value(t, a, [3]f32{-1, 3, 0}) // C++: a = u + v = (-1, 3, 0)

	// Vector subtraction: C++: XMVECTOR b = u - v;
	b := u - v
	testing.expect_value(t, b, [3]f32{3, 1, 6}) // C++: b = u - v = (3, 1, 6)

	// Scalar multiplication: C++: XMVECTOR c = 10.0f*u;
	c := 10 * u
	testing.expect_value(t, c, [3]f32{10, 20, 30}) // C++: c = 10 * u = (10, 20, 30)

	// ||u||
	// C++: XMVECTOR L = XMVector3Length(u);   — length splatted across all 4 lanes;
	// linalg returns a plain f32 (no splat, no XMVectorGetX).
	l := linalg.length(u)
	tu.expect_close(t, l, 3.74166, 1e-5) // C++: L = ||u|| = (3.74166, 3.74166, 3.74166)

	// d = u / ||u||
	// C++: XMVECTOR d = XMVector3Normalize(u);
	d := linalg.normalize(u)
	// C++: d = u / ||u|| = (0.267261, 0.534522, 0.801784)
	tu.expect_close(t, d, [3]f32{0.267261, 0.534522, 0.801784}, 1e-6)

	// s = u dot v
	// C++: XMVECTOR s = XMVector3Dot(u, v);   — dot splatted; plain f32 in linalg
	s := linalg.dot(u, v)
	testing.expect_value(t, s, -9) // C++: s = u.v = (-9, -9, -9)

	// e = u x v
	// C++: XMVECTOR e = XMVector3Cross(u, v);
	e := linalg.cross(u, v)
	testing.expect_value(t, e, [3]f32{-9, -3, 5}) // C++: e = u x v = (-9, -3, 5)

	// Find proj_n(w) and perp_n(w)
	// C++: XMVECTOR projW; XMVECTOR perpW;
	//      XMVector3ComponentsFromNormal(&projW, &perpW, w, n);
	proj_w := linalg.projection(w, n) // proj = n * dot(w, n)   (n is unit length)
	perp_w := w - proj_w //              perp = w - proj
	// Exact: dot(w, n) = 0.707 with no rounding, so the components come out bit-exact.
	testing.expect_value(t, proj_w, [3]f32{0.707, 0, 0}) // C++: projW = (0.707, 0, 0)
	testing.expect_value(t, perp_w, [3]f32{0, 0.707, 0}) // C++: perpW = (0, 0.707, 0)

	// Does projW + perpW == w?
	// C++: bool equal    = XMVector3Equal(projW + perpW, w) != 0;    → true
	//      bool notEqual = XMVector3NotEqual(projW + perpW, w) != 0; → false
	testing.expect(t, proj_w + perp_w == w)
	testing.expect(t, !(proj_w + perp_w != w))

	// The angle between projW and perpW should be 90 degrees.
	// C++: XMConvertToDegrees(XMVectorGetX(XMVector3AngleBetweenVectors(projW, perpW)))
	// linalg has no angle-between proc; acos of the normalized dot is all DXM does.
	cos_angle := linalg.dot(proj_w, perp_w) / (linalg.length(proj_w) * linalg.length(perp_w))
	angle_degrees := math.to_degrees(math.acos(cos_angle))
	tu.expect_close(t, angle_degrees, 90, 1e-4) // C++: angle = 90
}
