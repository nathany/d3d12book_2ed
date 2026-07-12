// Tiny float-comparison helpers for the math-chapter tests.
//
// core:testing's expect_value compares exactly; values transcribed from C++ cout output
// carry up to half a unit of rounding error in the 6th significant digit (cout's default),
// so those asserts need a tolerance. Same policy as the Rust port: exact values use
// expect_value, cout-rounded values use expect_close with an eps sized to the printed digit.
package test_util

import "core:testing"
import dm "../d3d_math"

expect_close_f32 :: proc(t: ^testing.T, actual, expected, eps: f32, loc := #caller_location) {
	testing.expectf(
		t,
		abs(actual - expected) <= eps,
		"expect_close: actual %v vs expected %v (eps %v)",
		actual, expected, eps,
		loc = loc,
	)
}

expect_close_vec :: proc(t: ^testing.T, actual, expected: [$N]f32, eps: f32, loc := #caller_location) {
	ok := true
	for i in 0 ..< N {
		ok &&= abs(actual[i] - expected[i]) <= eps
	}
	testing.expectf(
		t,
		ok,
		"expect_close: actual %v vs expected %v (eps %v)",
		actual, expected, eps,
		loc = loc,
	)
}

expect_close_mat4 :: proc(t: ^testing.T, actual, expected: dm.Mat4, eps: f32, loc := #caller_location) {
	ok := true
	for r in 0 ..< 4 {
		for c in 0 ..< 4 {
			ok &&= abs(actual[r, c] - expected[r, c]) <= eps
		}
	}
	testing.expectf(
		t,
		ok,
		"expect_close: actual %v vs expected %v (eps %v)",
		actual, expected, eps,
		loc = loc,
	)
}

expect_close :: proc {
	expect_close_f32,
	expect_close_vec,
	expect_close_mat4,
}
