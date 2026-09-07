// Test port of `Demos/C1_XMVECTOR/VectorOps.cpp` (commented out in the C++ project).
// Element-wise operations on 4-lane vectors. Traps that live here:
//
// - XMVectorLog/XMVectorExp are BASE 2 (log2/exp2) — the names lie. The C++ output proves
//   it: u = (1,2,4,8) → log (0,1,2,3); p = (2,2,1,0) → exp (4,4,2,1). Odin's linalg.log2/
//   exp2 say what they mean — but compute via ln·(1/ln 2) and e^(x·ln 2), so even
//   power-of-two results can be off by an ulp (unlike DXM/Rust): tolerances, not equality.
// - DirectXMath transcendentals are polynomial approximations (XMVectorCos is an 11-degree
//   minimax polynomial); Odin routes each lane through core:math. On the cos(π/2) lane the
//   C++ prints -1.19209e-07 vs libm-style -4.37e-08 — the cos assert's tolerance covers
//   that gap deliberately (same story as the Rust port).
package c1_xmvector

import "core:math"
import "core:math/linalg"
import "core:testing"
import tu "../test_util"

@(test)
vector_ops :: proc(t: ^testing.T) {
	// C++: XMVECTOR p = XMVectorSet(2.0f, 2.0f, 1.0f, 0.0f);
	//      XMVECTOR q = XMVectorSet(2.0f, -0.5f, 0.5f, 0.1f);
	//      XMVECTOR u = XMVectorSet(1.0f, 2.0f, 4.0f, 8.0f);
	//      XMVECTOR v = XMVectorSet(-2.0f, 1.0f, -3.0f, 2.5f);
	//      XMVECTOR w = XMVectorSet(0.0f, XM_PIDIV4, XM_PIDIV2, XM_PI);
	p := [4]f32{2, 2, 1, 0}
	q := [4]f32{2, -0.5, 0.5, 0.1}
	u := [4]f32{1, 2, 4, 8}
	v := [4]f32{-2, 1, -3, 2.5}
	w := [4]f32{0, math.PI / 4, math.PI / 2, math.PI}

	// C++: XMVectorAbs(v) = (2, 1, 3, 2.5)
	testing.expect_value(t, linalg.abs(v), [4]f32{2, 1, 3, 2.5})

	// C++: XMVectorCos(w) = (1, 0.707107, -1.19209e-07, -1)
	// eps 5e-7 covers cout's 6-significant-digit rounding on lane y and the
	// DXM-polynomial-vs-libm gap on lane z (see header).
	tu.expect_close(t, linalg.cos(w), [4]f32{1, 0.707107, -1.19209e-07, -1}, 5e-7)

	// C++: XMVectorLog(u) = (0, 1, 2, 3)   — base-2 logarithm!
	tu.expect_close(t, linalg.log2(u), [4]f32{0, 1, 2, 3}, 1e-6)

	// C++: XMVectorExp(p) = (4, 4, 2, 1)   — 2^x, not e^x!
	tu.expect_close(t, linalg.exp2(p), [4]f32{4, 4, 2, 1}, 1e-5)

	// C++: XMVectorPow(u, p) = (1, 4, 4, 1)  — element-wise with a vector exponent;
	// per-lane math.pow (no element-wise pow-by-vector in linalg).
	pow_up := [4]f32{
		math.pow(u.x, p.x),
		math.pow(u.y, p.y),
		math.pow(u.z, p.z),
		math.pow(u.w, p.w),
	}
	tu.expect_close(t, pow_up, [4]f32{1, 4, 4, 1}, 1e-5)

	// C++: XMVectorSqrt(u) = (1, 1.41421, 2, 2.82843)
	tu.expect_close(t, linalg.sqrt(u), [4]f32{1, 1.41421, 2, 2.82843}, 1e-5)

	// C++: XMVectorSwizzle(u, 2, 2, 1, 3) = (4, 4, 2, 8)   — built-in swizzles
	testing.expect_value(t, u.zzyw, [4]f32{4, 4, 2, 8})
	// C++: XMVectorSwizzle(u, 2, 1, 0, 3) = (4, 2, 1, 8)
	testing.expect_value(t, u.zyxw, [4]f32{4, 2, 1, 8})

	// C++: XMVectorMultiply(u, v) = (-2, 2, -12, 20)  — plain element-wise `*`
	testing.expect_value(t, u * v, [4]f32{-2, 2, -12, 20})

	// C++: XMVectorSaturate(q) = (1, 0, 0.5, 0.1)     — clamp to [0, 1]
	testing.expect_value(t, linalg.saturate(q), [4]f32{1, 0, 0.5, 0.1})

	// C++: XMVectorMin(p, v) = (-2, 1, -3, 0)
	testing.expect_value(t, linalg.min(p, v), [4]f32{-2, 1, -3, 0})
	// C++: XMVectorMax(p, v) = (2, 2, 1, 2.5)
	testing.expect_value(t, linalg.max(p, v), [4]f32{2, 2, 1, 2.5})
}
