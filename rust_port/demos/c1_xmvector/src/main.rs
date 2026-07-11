//! Port of `Demos/C1_XMVECTOR/xmvec3.cpp` (the variant left active in the C++ project).
//! The three commented-out mains in the C++ demo are `--bin` targets:
//! `cargo run -p c1_xmvector --bin init_functions` / `--bin vector_ops` / `--bin tol`.
//!
//! # DirectXMath → glam, the chapter 1 differences
//!
//! 1. **No load/store split.** `XMVECTOR` (SIMD register) vs `XMFLOAT3` (storage) and every
//!    `XMLoadFloat3`/`XMStoreFloat3` pair collapse into plain [`Vec3`]. The same type sits in
//!    structs and does math.
//! 2. **3D vectors are actually 3D.** `XMVECTOR` is always 4 lanes — the C++ sets `w = 0` and
//!    ignores it; `Vec3` simply has no `w`.
//! 3. **Scalar results are scalars.** `XMVector3Length`/`XMVector3Dot` return the result
//!    *splatted across all four lanes* (you extract with `XMVectorGetX`); glam's `length()`
//!    and `dot()` return plain `f32`, printed here as plain scalars.
//! 4. **Operators are the same.** `u + v`, `u - v`, `10.0 * u` port verbatim.
//! 5. `XMVector3ComponentsFromNormal(&proj, &perp, w, n)` →
//!    [`Vec3::project_onto_normalized`] + [`Vec3::reject_from_normalized`] — the identical
//!    formulas `proj = n · dot(w, n)`, `perp = w − proj` (both assume `n` is unit length).
//! 6. `XMVector3Equal` → `==` (exact component compare); `XMVector3AngleBetweenVectors` →
//!    [`Vec3::angle_between`] (radians as `f32`); `XMConvertToDegrees` → `.to_degrees()`.
//! 7. `XMVerifyCPUSupport` — deleted; SSE2 is part of the x86_64 baseline.
//! 8. **Formatting:** glam's `Display` prints `[x, y, z]` and honors std precision syntax
//!    (`{v:.6}` → 6 decimal places). The default `{}` prints each float's shortest exact
//!    round-trip form, so the same value shows more digits here than under C++ `cout`,
//!    which rounds to 6 *significant* digits (`3.7416575` here vs `3.74166` there).
//!
//! (Matrix differences — reversed multiplication order and transposed values — start in
//! chapter 2; see `Frank Luna RUST_PORTING_GUIDE.md`, "Matrices".)

use glam::vec3;

fn main() {
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

    // Vector subtraction: C++: XMVECTOR b = u - v;
    let b = u - v;

    // Scalar multiplication: C++: XMVECTOR c = 10.0f*u;
    let c = 10.0 * u;

    // ||u||
    // C++: XMVECTOR L = XMVector3Length(u);   // length splatted across all 4 lanes
    let l = u.length(); // glam: a plain f32 — no splat, no XMVectorGetX

    // d = u / ||u||
    // C++: XMVECTOR d = XMVector3Normalize(u);
    let d = u.normalize();

    // s = u dot v
    // C++: XMVECTOR s = XMVector3Dot(u, v);   // dot splatted across all 4 lanes
    let s = u.dot(v); // glam: a plain f32

    // e = u x v
    // C++: XMVECTOR e = XMVector3Cross(u, v);
    let e = u.cross(v);

    // Find proj_n(w) and perp_n(w)
    // C++: XMVECTOR projW; XMVECTOR perpW;
    //      XMVector3ComponentsFromNormal(&projW, &perpW, w, n);
    let proj_w = w.project_onto_normalized(n); // proj = n * dot(w, n)
    let perp_w = w.reject_from_normalized(n); //  perp = w - proj

    // Does projW + perpW == w?
    // C++: bool equal    = XMVector3Equal(projW + perpW, w) != 0;
    //      bool notEqual = XMVector3NotEqual(projW + perpW, w) != 0;
    let equal = proj_w + perp_w == w;
    let not_equal = proj_w + perp_w != w;

    // The angle between projW and perpW should be 90 degrees.
    // C++: XMVECTOR angleVec = XMVector3AngleBetweenVectors(projW, perpW);
    //      float angleRadians = XMVectorGetX(angleVec);
    //      float angleDegrees = XMConvertToDegrees(angleRadians);
    let angle_degrees = proj_w.angle_between(perp_w).to_degrees();

    println!("u                   = {u}");
    println!("v                   = {v}");
    println!("w                   = {w}");
    println!("n                   = {n}");
    println!("a = u + v           = {a}");
    println!("b = u - v           = {b}");
    println!("c = 10 * u          = {c}");
    println!("d = u / ||u||       = {d}");
    println!("e = u x v           = {e}");
    println!("L  = ||u||          = {l}");
    println!("s = u.v             = {s}");
    println!("projW               = {proj_w}");
    println!("perpW               = {perp_w}");
    println!("projW + perpW == w  = {equal}");
    println!("projW + perpW != w  = {not_equal}");
    println!("angle               = {angle_degrees}");
}
