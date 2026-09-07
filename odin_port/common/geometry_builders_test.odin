package common

import "core:testing"

@(test)
skull_count_boundaries :: proc(t: ^testing.T) {
	invalid := [?][3]int{
		{-1, 1, 100}, {0, 1, 100}, {1, -1, 100}, {1, 0, 100},
		{1, 1, -1}, {1000000, 1, 100}, {1, 1000000, 100},
		{max(int), 1, max(int)}, {1, max(int), max(int)},
	}
	for args in invalid {
		_, _, ok := skull_buffer_sizes(args[0], args[1], args[2])
		testing.expectf(t, !ok, "invalid counts accepted: %v", args)
	}
	// A minimal triangle fits; a file too short even for the numeric tokens does not.
	vb, ib, ok := skull_buffer_sizes(3, 1, 21)
	testing.expect(t, ok)
	testing.expect_value(t, vb, u32(132))
	testing.expect_value(t, ib, u32(12))
	_, _, ok = skull_buffer_sizes(3, 1, 20)
	testing.expect(t, !ok)
	// Exercise exact allocation/view-size boundaries without allocating those buffers.
	limit := min(u64(max(u32)), u64(max(int)))
	vmax := int(limit / size_of(Model_Vertex))
	tmax := int(limit / (3 * size_of(i32)))
	_, _, ok = skull_buffer_sizes(vmax, 1, max(int))
	testing.expect(t, ok)
	_, _, ok = skull_buffer_sizes(vmax + 1, 1, max(int))
	testing.expect(t, !ok)
	_, _, ok = skull_buffer_sizes(3, tmax, max(int))
	testing.expect(t, ok)
	_, _, ok = skull_buffer_sizes(3, tmax + 1, max(int))
	testing.expect(t, !ok)
}

@(test)
skull_index_boundaries :: proc(t: ^testing.T) {
	testing.expect(t, skull_index_valid(0, 3))
	testing.expect(t, skull_index_valid(2, 3))
	for index in ([?]int{-1, 3, max(int)}) {
		testing.expectf(t, !skull_index_valid(index, 3), "invalid index accepted: %d", index)
	}
	when size_of(int) > size_of(i32) {
		testing.expect(t, skull_index_valid(int(max(i32)), int(max(i32)) + 1))
		testing.expect(t, !skull_index_valid(int(max(i32)) + 1, int(max(i32)) + 2))
	}
}
