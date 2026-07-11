//! Chapter 3 (Transformations) as tests:
//!
//! ```text
//! cargo test -p c3_transformations
//! ```
//!
//! Chapter 3 has **no demo in the book's source** — these tests exercise the DirectXMath
//! functions the chapter covers, asserting against output captured from a small C++
//! ground-truth program (`XMMatrixRotationY`, `S*R*T` composition,
//! `XMVector3TransformCoord`/`TransformNormal`, `XMMatrixRotationAxis`,
//! `XMMatrixRotationRollPitchYaw`; x64, 2026-07).
//!
//! # DirectXMath → glam, the chapter 3 differences
//!
//! 1. **This is the chapter where the convention flip becomes muscle memory.** Every
//!    composition in the book reads left-to-right (`S * R * T`: scale, then rotate, then
//!    translate); in glam the same chain is written right-to-left (`T * R * S`). Same
//!    transforms, same result on points — reversed spelling.
//! 2. **The builders all exist**: `XMMatrixScaling/Translation` → [`glam::Mat4::from_scale`]
//!    / [`from_translation`]; `XMMatrixRotationX/Y/Z` → [`from_rotation_x`]/[`_y`]/[`_z`];
//!    `XMMatrixRotationAxis` → [`from_axis_angle`] (glam **requires a normalized axis**;
//!    DXM normalizes internally); `XMMatrixRotationRollPitchYaw` → [`from_euler`].
//! 3. **Roll-pitch-yaw argument mapping** (verified below):
//!    `XMMatrixRotationRollPitchYaw(pitch, yaw, roll)` applies roll (z), then pitch (x),
//!    then yaw (y) — in glam that is `Mat4::from_euler(EulerRot::YXZ, yaw, pitch, roll)`
//!    (arguments follow the letters of the `EulerRot` order), or equivalently the explicit
//!    product `from_rotation_y(yaw) * from_rotation_x(pitch) * from_rotation_z(roll)`.
//! 4. **Transforming points vs vectors**: `XMVector3TransformCoord(v, M)` →
//!    [`glam::Mat4::transform_point3`] (w = 1; for affine matrices) or
//!    [`project_point3`] (adds the divide-by-w — what TransformCoord actually does; the two
//!    agree on affine matrices). `XMVector3TransformNormal(v, M)` →
//!    [`transform_vector3`] (w = 0: rotates/scales, ignores translation).
//! 5. **DXM's `XMScalarSinCos` is an approximation** (like chapter 1's `XMVectorCos`):
//!    its RotationY(π/4) has cos = 0.70710671 where libm says 0.70710677 — hence the small
//!    tolerances even on "clean" rotation matrices.
//!
//! As in chapter 2: the C++ prints matrix *rows*; the equivalent glam matrix has them as
//! *columns*, so matrix asserts check `m.col(i)` against printed row `i`.
//!
//! [`from_translation`]: glam::Mat4::from_translation
//! [`from_rotation_x`]: glam::Mat4::from_rotation_x
//! [`_y`]: glam::Mat4::from_rotation_y
//! [`_z`]: glam::Mat4::from_rotation_z
//! [`from_axis_angle`]: glam::Mat4::from_axis_angle
//! [`from_euler`]: glam::Mat4::from_euler
//! [`project_point3`]: glam::Mat4::project_point3
//! [`transform_vector3`]: glam::Mat4::transform_vector3

#[cfg(test)]
mod tests {
    use common::testing::{assert_close3, assert_close4};
    use glam::{EulerRot, Mat4, vec3, vec4};
    use std::f32::consts::FRAC_PI_4;

    /// C++: XMMATRIX Ry = XMMatrixRotationY(XM_PIDIV4);
    #[test]
    fn rotation_y() {
        let ry = Mat4::from_rotation_y(FRAC_PI_4);
        // C++ output rows (note DXM's approximated cos, point 5 in the crate docs):
        //   0.70710671  0  -0.70710677  0
        //   0           1   0           0
        //   0.70710677  0   0.70710671  0
        //   0           0   0           1
        assert_close4(ry.col(0), vec4(0.70710671, 0.0, -0.70710677, 0.0), 1e-6);
        assert_close4(ry.col(1), vec4(0.0, 1.0, 0.0, 0.0), 1e-6);
        assert_close4(ry.col(2), vec4(0.70710677, 0.0, 0.70710671, 0.0), 1e-6);
        assert_close4(ry.col(3), vec4(0.0, 0.0, 0.0, 1.0), 1e-6);
    }

    /// The chapter's core lesson: composing scale → rotate → translate.
    /// C++: XMMATRIX M = S * Ry * T;   (row-vector: reads left-to-right)
    #[test]
    fn srt_composition() {
        let s = Mat4::from_scale(vec3(0.5, 2.0, 1.5));
        let ry = Mat4::from_rotation_y(FRAC_PI_4);
        let t = Mat4::from_translation(vec3(1.0, 2.0, 3.0));

        // glam (column-vector): the same chain is written in REVERSE — T * Ry * S.
        let m = t * ry * s;

        // C++ output rows of M = S*Ry*T:
        //   0.35355335  0  -0.35355338  0
        //   0           2   0           0
        //   1.0606601   0   1.0606601   0
        //   1           2   3           1
        assert_close4(m.col(0), vec4(0.35355335, 0.0, -0.35355338, 0.0), 1e-6);
        assert_close4(m.col(1), vec4(0.0, 2.0, 0.0, 0.0), 1e-6);
        assert_close4(m.col(2), vec4(1.0606601, 0.0, 1.0606601, 0.0), 1e-6);
        assert_close4(m.col(3), vec4(1.0, 2.0, 3.0, 1.0), 1e-6);

        // C++: XMVector3TransformCoord(p, M) = (2.4142134, 4, 3.7071071, 1)
        let p = vec3(1.0, 1.0, 1.0);
        let q = m.transform_point3(p);
        assert_close3(q, vec3(2.4142134, 4.0, 3.7071071), 1e-6);
        // project_point3 is the exact TransformCoord equivalent (divides by w); for an
        // affine M they agree.
        assert_eq!(m.project_point3(p), q);

        // C++: XMVector3TransformNormal(n, M) = (1.0606601, 0, 1.0606601, 0)
        // w = 0: the translation row contributes nothing.
        let n = vec3(0.0, 0.0, 1.0);
        assert_close3(m.transform_vector3(n), vec3(1.0606601, 0.0, 1.0606601), 1e-6);

        // The didactic negative: writing the book's order verbatim in glam is a DIFFERENT
        // transform (translate first, then scale — the translation gets scaled).
        let wrong = s * ry * t;
        assert_ne!(wrong.transform_point3(p), q);
    }

    /// C++: XMMATRIX Ra = XMMatrixRotationAxis(axis, 0.5f);
    #[test]
    fn rotation_about_arbitrary_axis() {
        // glam requires the axis normalized (DXM's RotationAxis normalizes internally —
        // its RotationNormal variant is the one that matches glam's contract).
        let axis = vec3(1.0, 2.0, 3.0).normalize();
        let ra = Mat4::from_axis_angle(axis, 0.5);
        // C++: TransformCoord(p, Ra) = (0.80191535, 1.2387755, 0.90684456, 1)
        let q = ra.transform_point3(vec3(1.0, 1.0, 1.0));
        assert_close3(q, vec3(0.80191535, 1.2387755, 0.90684456), 1e-6);
    }

    /// C++: XMMATRIX Rpy = XMMatrixRotationRollPitchYaw(0.3f, 0.7f, 1.1f);
    ///      (arguments: pitch = 0.3 about x, yaw = 0.7 about y, roll = 1.1 about z;
    ///       applied roll first, then pitch, then yaw)
    #[test]
    fn roll_pitch_yaw() {
        // glam: EulerRot::YXZ with arguments following the letters — (yaw, pitch, roll).
        let rpy = Mat4::from_euler(EulerRot::YXZ, 0.7, 0.3, 1.1);

        // …which is exactly this explicit product (roll applied first — rightmost):
        let explicit = Mat4::from_rotation_y(0.7)
            * Mat4::from_rotation_x(0.3)
            * Mat4::from_rotation_z(1.1);
        for i in 0..4 {
            assert_close4(rpy.col(i), explicit.col(i), 1e-6);
        }

        // C++: TransformCoord(p, Rpy) = (0.53676397, 0.98921961, 1.3165594, 1)
        let q = rpy.transform_point3(vec3(1.0, 1.0, 1.0));
        assert_close3(q, vec3(0.53676397, 0.98921961, 1.3165594), 1e-6);
    }
}
