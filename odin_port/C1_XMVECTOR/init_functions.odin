// Test port of `Demos/C1_XMVECTOR/InitFunctions.cpp` (commented out in the C++ project).
// The DirectXMath "setter" functions all become literals or swizzles. All values are exact —
// asserts come straight from the C++ output.
package c1_xmvector

import "core:testing"

@(test)
init_functions :: proc(t: ^testing.T) {
	// C++: XMVECTOR p = XMVectorZero();   — zero-init is Odin's default
	p: [3]f32
	testing.expect_value(t, p, [3]f32{0, 0, 0}) // C++: p = (0, 0, 0)

	// C++: XMVECTOR q = XMVectorSplatOne();
	q := [3]f32{1, 1, 1}
	testing.expect_value(t, q, [3]f32{1, 1, 1}) // C++: q = (1, 1, 1)

	// C++: XMVECTOR u = XMVectorSet(1.0f, 2.0f, 3.0f, 0.0f);
	u := [3]f32{1, 2, 3}
	testing.expect_value(t, u, [3]f32{1, 2, 3}) // C++: u = (1, 2, 3)

	// C++: XMVECTOR v = XMVectorReplicate(-2.0f);
	v := [3]f32{-2, -2, -2}
	testing.expect_value(t, v, [3]f32{-2, -2, -2}) // C++: v = (-2, -2, -2)

	// C++: XMVECTOR w = XMVectorSplatZ(u);   — a built-in swizzle in Odin
	w := u.zzz
	testing.expect_value(t, w, [3]f32{3, 3, 3}) // C++: w = (3, 3, 3)
}
