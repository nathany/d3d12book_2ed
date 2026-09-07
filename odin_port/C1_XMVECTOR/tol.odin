// Test port of `Demos/C1_XMVECTOR/tol.cpp` (commented out in the C++ project).
// The book's floating-point-tolerance lesson: normalizing (1,1,1) does NOT give a vector of
// length exactly 1 — which is precisely what this test asserts.
package c1_xmvector

import "core:math"
import "core:math/linalg"
import "core:testing"
import tu "../test_util"

@(test)
tol :: proc(t: ^testing.T) {
	// C++: XMVECTOR u = XMVectorSet(1.0f, 1.0f, 1.0f, 0.0f);
	u := [3]f32{1, 1, 1}
	// C++: XMVECTOR n = XMVector3Normalize(u);
	n := linalg.normalize(u)
	// C++: float LU = XMVectorGetX(XMVector3Length(n));
	lu := linalg.length(n)

	// Mathematically, the length should be 1.  Is it numerically?
	// C++ (cout.precision(8)) prints 0.99999994. The exact float depends on the normalize
	// implementation's op order (DXM divides; glam and linalg may multiply by the
	// reciprocal), so this is a tolerance assert; the *lesson* assert below is the one
	// that must always hold.
	tu.expect_close(t, lu, 0.99999994, 1e-7)

	// C++: prints "Length not 1" — the chapter's point.
	testing.expect(t, lu != 1.0)

	// Raising 1 to any power should still be 1.  Is it?
	// C++: float powLU = powf(LU, 1.0e6f);  → 0.94213694
	pow_lu := math.pow(lu, 1.0e6)
	tu.expect_close(t, pow_lu, 0.94213694, 1e-6)
}
