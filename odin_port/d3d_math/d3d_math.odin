// The port's DirectXMath-convention math layer — the guide's `d3d_math.odin`, started at
// chapter 3 as planned. Every matrix builder here is typed from the book's *printed* form
// (the chapter derives each one); do NOT replace them with core:math/linalg's builders,
// which are GL-flavored column-vector (the transpose of these, with [-1,1] depth for
// projections). linalg's convention-agnostic operations (dot, cross, normalize, inverse,
// transpose, element-wise math) are safe and used throughout.
package d3d_math

import "core:math"

Vec3 :: [3]f32
Vec4 :: [4]f32

// The one place the convention is decided (see the porting guide's Matrices section):
// #row_major changes only the in-memory layout — indexing, operators, and math are
// identical — making Mat4 byte-identical to XMFLOAT4X4. Combined with the book's
// row-vector convention (v' = v * M, concatenate left-to-right), every matrix line in the
// book ports literally: literals as printed, `world * view * proj` order preserved, and
// the XMMatrixTranspose-before-CB-upload line survives as linalg.transpose.
Mat4 :: #row_major matrix[4, 4]f32

// C++: XMMatrixIdentity()  — a scalar cast fills the diagonal.
MAT4_IDENTITY :: Mat4(1)

// C++: XMMatrixScaling(x, y, z)  — book §3.4.1.
scaling :: proc(x, y, z: f32) -> Mat4 {
	return Mat4{
		x, 0, 0, 0,
		0, y, 0, 0,
		0, 0, z, 0,
		0, 0, 0, 1,
	}
}

// C++: XMMatrixTranslation(x, y, z)  — book §3.4.3; offsets in the last ROW (row-vector).
translation :: proc(x, y, z: f32) -> Mat4 {
	return Mat4{
		1, 0, 0, 0,
		0, 1, 0, 0,
		0, 0, 1, 0,
		x, y, z, 1,
	}
}

// C++: XMMatrixRotationX(angle)  — book §3.4.2.
rotation_x :: proc(angle: f32) -> Mat4 {
	s, c := math.sin(angle), math.cos(angle)
	return Mat4{
		1, 0, 0, 0,
		0, c, s, 0,
		0, -s, c, 0,
		0, 0, 0, 1,
	}
}

// C++: XMMatrixRotationY(angle)  — book §3.4.2.
rotation_y :: proc(angle: f32) -> Mat4 {
	s, c := math.sin(angle), math.cos(angle)
	return Mat4{
		c, 0, -s, 0,
		0, 1, 0, 0,
		s, 0, c, 0,
		0, 0, 0, 1,
	}
}

// C++: XMMatrixRotationZ(angle)  — book §3.4.2.
rotation_z :: proc(angle: f32) -> Mat4 {
	s, c := math.sin(angle), math.cos(angle)
	return Mat4{
		c, s, 0, 0,
		-s, c, 0, 0,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
}

// C++: XMMatrixRotationAxis(axis, angle)  — the book's Rodrigues form (§3.4.2, eq. 3.20),
// row-vector arrangement. NOTE: `axis` must be unit length here (DXM's RotationAxis
// normalizes internally; this matches its RotationNormal variant, like glam).
rotation_axis :: proc(axis: Vec3, angle: f32) -> Mat4 {
	s, c := math.sin(angle), math.cos(angle)
	x, y, z := axis.x, axis.y, axis.z
	omc := 1 - c // "one minus cosine"
	return Mat4{
		c + omc*x*x,   omc*x*y + s*z, omc*x*z - s*y, 0,
		omc*x*y - s*z, c + omc*y*y,   omc*y*z + s*x, 0,
		omc*x*z + s*y, omc*y*z - s*x, c + omc*z*z,   0,
		0,             0,             0,             1,
	}
}

// C++: XMMatrixRotationRollPitchYaw(pitch, yaw, roll)  — applies roll (z) first, then
// pitch (x), then yaw (y). Row-vector: v·Rz·Rx·Ry, i.e. left-to-right in book order.
rotation_roll_pitch_yaw :: proc(pitch, yaw, roll: f32) -> Mat4 {
	return rotation_z(roll) * rotation_x(pitch) * rotation_y(yaw)
}

// C++: XMVector3TransformCoord(v, m)  — w = 1, with the divide-by-w DXM performs
// (a no-op for affine matrices; required once projections appear in ch 5).
transform_coord :: proc(v: Vec3, m: Mat4) -> Vec3 {
	q := Vec4{v.x, v.y, v.z, 1} * m
	return q.xyz / q.w
}

// C++: XMVector3TransformNormal(v, m)  — w = 0 kills the translation row.
transform_normal :: proc(v: Vec3, m: Mat4) -> Vec3 {
	return (Vec4{v.x, v.y, v.z, 0} * m).xyz
}
