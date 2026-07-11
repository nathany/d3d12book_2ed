//! Port of `Demos/C1_XMVECTOR` — chapter 1's console demos as **tests**:
//!
//! ```text
//! cargo test -p c1_xmvector
//! ```
//!
//! Each of the C++ demo's four alternative `main`s (one active, three commented out) is one
//! `#[test]` below, named after its `.cpp` file and asserting against values captured from
//! the C++ demos' actual output (x64, 2026-07). Exact values (integers, inputs echoed back)
//! use `assert_eq!`; values `cout` rounded to 6 significant digits use
//! [`common::testing::assert_close`] with a tolerance sized to the 6th digit (up to 5e-7 of
//! rounding error relative to it).
//!
//! # DirectXMath → glam, the chapter 1 differences
//!
//! 1. **No load/store split.** `XMVECTOR` (SIMD register) vs `XMFLOAT3` (storage) and every
//!    `XMLoadFloat3`/`XMStoreFloat3` pair collapse into plain [`glam::Vec3`]. The same type
//!    sits in structs and does math.
//! 2. **3D vectors are actually 3D.** `XMVECTOR` is always 4 lanes — the C++ sets `w = 0`
//!    and ignores it; `Vec3` simply has no `w`.
//! 3. **Scalar results are scalars.** `XMVector3Length`/`XMVector3Dot` return the result
//!    *splatted across all four lanes* (you extract with `XMVectorGetX`); glam's `length()`
//!    and `dot()` return plain `f32`.
//! 4. **Operators are the same.** `u + v`, `u - v`, `10.0 * u` port verbatim.
//! 5. `XMVector3ComponentsFromNormal(&proj, &perp, w, n)` →
//!    [`glam::Vec3::project_onto_normalized`] + [`glam::Vec3::reject_from_normalized`] — the
//!    identical formulas `proj = n · dot(w, n)`, `perp = w − proj` (both assume `n` is unit
//!    length).
//! 6. `XMVector3Equal` → `==` (exact component compare); `XMVector3AngleBetweenVectors` →
//!    [`glam::Vec3::angle_between`] (radians as `f32`); `XMConvertToDegrees` →
//!    `.to_degrees()`.
//! 7. **`XMVectorLog`/`XMVectorExp` are base 2** (`log2`/`exp2`) — the names lie; glam's
//!    `log2()`/`exp2()` say what they mean.
//! 8. **DirectXMath transcendentals are polynomial approximations** (`XMVectorCos` is an
//!    11-degree minimax polynomial); Rust routes each lane through libm, so results differ
//!    in the last ulps (see the cos(π/2) lane in [`tests::vector_ops`]).
//! 9. `XMVerifyCPUSupport` — deleted; SSE2 is part of the x86_64 baseline.
//!
//! (Matrix differences — reversed multiplication order and transposed values — start in
//! chapter 2; see `Frank Luna RUST_PORTING_GUIDE.md`, "Matrices".)

#[cfg(test)]
mod tests {
    use common::testing::{assert_close, assert_close3, assert_close4};
    use glam::{Vec3, Vec3Swizzles, Vec4, Vec4Swizzles, vec3, vec4};

    /// Port of `xmvec3.cpp` (the variant left active in the C++ project).
    #[test]
    fn xmvec3() {
        // C++: XMVECTOR n = XMVectorSet(1.0f, 0.0f, 0.0f, 0.0f);
        //      XMVECTOR u = XMVectorSet(1.0f, 2.0f, 3.0f, 0.0f);
        //      XMVECTOR v = XMVectorSet(-2.0f, 1.0f, -3.0f, 0.0f);
        //      XMVECTOR w = XMVectorSet(0.707f, 0.707f, 0.0f, 0.0f);
        let n = vec3(1.0, 0.0, 0.0);
        let u = vec3(1.0, 2.0, 3.0);
        let v = vec3(-2.0, 1.0, -3.0);
        let w = vec3(0.707, 0.707, 0.0);

        // Vector addition: C++: XMVECTOR a = u + v;
        let a = u + v;
        assert_eq!(a, vec3(-1.0, 3.0, 0.0)); // C++: a = u + v = (-1, 3, 0)

        // Vector subtraction: C++: XMVECTOR b = u - v;
        let b = u - v;
        assert_eq!(b, vec3(3.0, 1.0, 6.0)); // C++: b = u - v = (3, 1, 6)

        // Scalar multiplication: C++: XMVECTOR c = 10.0f*u;
        let c = 10.0 * u;
        assert_eq!(c, vec3(10.0, 20.0, 30.0)); // C++: c = 10 * u = (10, 20, 30)

        // ||u||
        // C++: XMVECTOR L = XMVector3Length(u);   — length splatted across all 4 lanes;
        // glam returns a plain f32 (no splat, no XMVectorGetX).
        let l = u.length();
        assert_close(l, 3.74166, 1e-5); // C++: L = ||u|| = (3.74166, 3.74166, 3.74166)

        // d = u / ||u||
        // C++: XMVECTOR d = XMVector3Normalize(u);
        let d = u.normalize();
        // C++: d = u / ||u|| = (0.267261, 0.534522, 0.801784)
        assert_close3(d, vec3(0.267261, 0.534522, 0.801784), 1e-6);

        // s = u dot v
        // C++: XMVECTOR s = XMVector3Dot(u, v);   — dot splatted; plain f32 in glam
        let s = u.dot(v);
        assert_eq!(s, -9.0); // C++: s = u.v = (-9, -9, -9)

        // e = u x v
        // C++: XMVECTOR e = XMVector3Cross(u, v);
        let e = u.cross(v);
        assert_eq!(e, vec3(-9.0, -3.0, 5.0)); // C++: e = u x v = (-9, -3, 5)

        // Find proj_n(w) and perp_n(w)
        // C++: XMVector3ComponentsFromNormal(&projW, &perpW, w, n);
        let proj_w = w.project_onto_normalized(n); // proj = n * dot(w, n)
        let perp_w = w.reject_from_normalized(n); //  perp = w - proj
        // Exact: dot(w, n) = 0.707 with no rounding, so the components come out bit-exact.
        assert_eq!(proj_w, vec3(0.707, 0.0, 0.0)); // C++: projW = (0.707, 0, 0)
        assert_eq!(perp_w, vec3(0.0, 0.707, 0.0)); // C++: perpW = (0, 0.707, 0)

        // Does projW + perpW == w?
        // C++: XMVector3Equal(projW + perpW, w)    → true
        //      XMVector3NotEqual(projW + perpW, w) → false
        assert!(proj_w + perp_w == w);
        assert!(!(proj_w + perp_w != w));

        // The angle between projW and perpW should be 90 degrees.
        // C++: XMConvertToDegrees(XMVectorGetX(XMVector3AngleBetweenVectors(projW, perpW)))
        let angle_degrees = proj_w.angle_between(perp_w).to_degrees();
        assert_close(angle_degrees, 90.0, 1e-4); // C++: angle = 90
    }

    /// Port of `InitFunctions.cpp`. The DirectXMath "setter" functions all become constants
    /// or constructors; `XMVectorSplatZ` becomes a swizzle method. All values are exact.
    #[test]
    fn init_functions() {
        // C++: XMVECTOR p = XMVectorZero();
        let p = Vec3::ZERO;
        assert_eq!(p, vec3(0.0, 0.0, 0.0)); // C++: p = (0, 0, 0)

        // C++: XMVECTOR q = XMVectorSplatOne();
        let q = Vec3::ONE;
        assert_eq!(q, vec3(1.0, 1.0, 1.0)); // C++: q = (1, 1, 1)

        // C++: XMVECTOR u = XMVectorSet(1.0f, 2.0f, 3.0f, 0.0f);
        let u = vec3(1.0, 2.0, 3.0);
        assert_eq!(u, vec3(1.0, 2.0, 3.0)); // C++: u = (1, 2, 3)

        // C++: XMVECTOR v = XMVectorReplicate(-2.0f);
        let v = Vec3::splat(-2.0);
        assert_eq!(v, vec3(-2.0, -2.0, -2.0)); // C++: v = (-2, -2, -2)

        // C++: XMVECTOR w = XMVectorSplatZ(u);
        let w = u.zzz(); // Vec3Swizzles trait
        assert_eq!(w, vec3(3.0, 3.0, 3.0)); // C++: w = (3, 3, 3)
    }

    /// Port of `VectorOps.cpp`: element-wise operations on 4-lane vectors. The base-2
    /// `XMVectorLog`/`XMVectorExp` trap and the polynomial-cos difference (crate docs,
    /// points 7–8) both live here.
    #[test]
    fn vector_ops() {
        // C++: XMVECTOR p = XMVectorSet(2.0f, 2.0f, 1.0f, 0.0f);
        //      XMVECTOR q = XMVectorSet(2.0f, -0.5f, 0.5f, 0.1f);
        //      XMVECTOR u = XMVectorSet(1.0f, 2.0f, 4.0f, 8.0f);
        //      XMVECTOR v = XMVectorSet(-2.0f, 1.0f, -3.0f, 2.5f);
        //      XMVECTOR w = XMVectorSet(0.0f, XM_PIDIV4, XM_PIDIV2, XM_PI);
        use std::f32::consts::{FRAC_PI_2, FRAC_PI_4, PI};
        let p = vec4(2.0, 2.0, 1.0, 0.0);
        let q = vec4(2.0, -0.5, 0.5, 0.1);
        let u = vec4(1.0, 2.0, 4.0, 8.0);
        let v = vec4(-2.0, 1.0, -3.0, 2.5);
        let w = vec4(0.0, FRAC_PI_4, FRAC_PI_2, PI);

        // C++: XMVectorAbs(v) = (2, 1, 3, 2.5)
        assert_eq!(v.abs(), vec4(2.0, 1.0, 3.0, 2.5));

        // C++: XMVectorCos(w) = (1, 0.707107, -1.19209e-07, -1)
        // eps 5e-7 covers cout's 6-significant-digit rounding on lane y (0.70710677 printed
        // as 0.707107, up to half a unit in the 6th digit) and the DXM-polynomial-vs-libm
        // gap on lane z (-4.37114e-08 here vs -1.19209e-07 there).
        assert_close4(w.cos(), vec4(1.0, 0.707107, -1.19209e-7, -1.0), 5e-7);

        // C++: XMVectorLog(u) = (0, 1, 2, 3)   — base-2 logarithm!
        assert_eq!(u.log2(), vec4(0.0, 1.0, 2.0, 3.0));

        // C++: XMVectorExp(p) = (4, 4, 2, 1)   — 2^x, not e^x!
        assert_eq!(p.exp2(), vec4(4.0, 4.0, 2.0, 1.0));

        // C++: XMVectorPow(u, p) = (1, 4, 4, 1)  — element-wise with a *vector* exponent;
        // glam's `powf` takes a scalar exponent, so this one is spelled out per lane.
        let pow_up = vec4(
            u.x.powf(p.x),
            u.y.powf(p.y),
            u.z.powf(p.z),
            u.w.powf(p.w),
        );
        assert_eq!(pow_up, vec4(1.0, 4.0, 4.0, 1.0));

        // C++: XMVectorSqrt(u) = (1, 1.41421, 2, 2.82843)
        assert_close4(u.sqrt(), vec4(1.0, 1.41421, 2.0, 2.82843), 1e-5);

        // C++: XMVectorSwizzle(u, 2, 2, 1, 3) = (4, 4, 2, 8)
        assert_eq!(u.zzyw(), vec4(4.0, 4.0, 2.0, 8.0));
        // C++: XMVectorSwizzle(u, 2, 1, 0, 3) = (4, 2, 1, 8)
        assert_eq!(u.zyxw(), vec4(4.0, 2.0, 1.0, 8.0));

        // C++: XMVectorMultiply(u, v) = (-2, 2, -12, 20)  — plain element-wise `*` in glam
        assert_eq!(u * v, vec4(-2.0, 2.0, -12.0, 20.0));

        // C++: XMVectorSaturate(q) = (1, 0, 0.5, 0.1)     — clamp to [0, 1]
        assert_eq!(q.clamp(Vec4::ZERO, Vec4::ONE), vec4(1.0, 0.0, 0.5, 0.1));

        // C++: XMVectorMin(p, v) = (-2, 1, -3, 0)
        assert_eq!(p.min(v), vec4(-2.0, 1.0, -3.0, 0.0));
        // C++: XMVectorMax(p, v) = (2, 2, 1, 2.5)
        assert_eq!(p.max(v), vec4(2.0, 2.0, 1.0, 2.5));
    }

    /// Port of `tol.cpp`: the book's floating-point-tolerance lesson — normalizing (1,1,1)
    /// does **not** give a vector of length exactly 1, which is precisely what this asserts.
    #[test]
    fn tol() {
        // C++: XMVECTOR u = XMVectorSet(1.0f, 1.0f, 1.0f, 0.0f);
        let u = vec3(1.0, 1.0, 1.0);
        // C++: XMVECTOR n = XMVector3Normalize(u);
        let n = u.normalize();
        // C++: float LU = XMVectorGetX(XMVector3Length(n));
        let lu = n.length();

        // Mathematically, the length should be 1.  Is it numerically?
        // C++ (cout.precision(8)) prints 0.99999994 — glam currently reproduces
        // DirectXMath's result bit-for-bit here. If a future glam changes its normalize
        // float ops, this may drift by an ulp; the *lesson* assert below is the one that
        // must always hold.
        assert_close(lu, 0.99999994, 1e-7);

        // C++: prints "Length not 1" — the chapter's point.
        assert_ne!(lu, 1.0);

        // Raising 1 to any power should still be 1.  Is it?
        // C++: float powLU = powf(LU, 1.0e6f);  → 0.94213694
        let pow_lu = lu.powf(1.0e6);
        assert_close(pow_lu, 0.94213694, 1e-6);
    }
}
