//! Port of `Demos/C2_XMMATRIX/xmmatrix.cpp` — chapter 2's console demo as tests:
//!
//! ```text
//! cargo test -p c2_xmmatrix
//! ```
//!
//! # DirectXMath → glam, the chapter 2 differences (matrices begin here)
//!
//! 1. **The convention flip.** `XMMATRIX` is row-major storage with the row-vector
//!    convention (`v' = v·M`); [`glam::Mat4`] is column-major storage with the column-vector
//!    convention (`v' = M·v`). The equivalent glam matrix is the **transpose** of the book's
//!    printed matrix — translation lives in the last *column* here, last *row* in the book.
//! 2. **…but the bytes agree.** Row-major storage of a row-convention matrix and
//!    column-major storage of the equivalent column-convention matrix are the *same 16
//!    numbers in the same order*. So the C++ `XMMATRIX A(…16 literals…)` ports as
//!    `Mat4::from_cols_array(&[…the same 16 literals…])` — copy them verbatim and the
//!    convention flip happens by itself. (The same identity is why the post-book
//!    "no-transpose CB upload" path works; see the guide's Matrices section.)
//! 3. **Concatenation reverses.** C++ `A * B` (apply A, then B) is glam `B * A`. This is
//!    the one edit you must make on every matrix product in the book.
//! 4. **The C++ demo prints matrix rows; ours are columns.** Every matrix assert below
//!    checks `m.col(i)` against row `i` of the C++ output — seeing that correspondence over
//!    and over is the point of this chapter's port.
//! 5. **Convention-agnostic ops are unchanged.** `transpose`, `determinant` (a plain `f32`
//!    here — DXM splats it across a vector), and `inverse` (glam takes no determinant
//!    out-param; call `determinant()` separately if you need it).
//!
//! Expected values are the C++ demo's actual output (x64, 2026-07); every number in this
//! demo happens to be exactly representable, so the asserts are exact.

#[cfg(test)]
mod tests {
    use glam::{Mat4, vec3, vec4};

    /// Port of `xmmatrix.cpp`'s `main`.
    #[test]
    fn xmmatrix() {
        // C++: XMMATRIX A(1.0f, 0.0f, 0.0f, 0.0f,
        //                 0.0f, 2.0f, 0.0f, 0.0f,
        //                 0.0f, 0.0f, 4.0f, 0.0f,
        //                 1.0f, 2.0f, 3.0f, 1.0f);
        // Same 16 literals, same order (point 2 above): XMMATRIX fills rows, from_cols_array
        // fills columns, and that is exactly the row↔column-vector convention flip.
        #[rustfmt::skip]
        let a = Mat4::from_cols_array(&[
            1.0, 0.0, 0.0, 0.0,
            0.0, 2.0, 0.0, 0.0,
            0.0, 0.0, 4.0, 0.0,
            1.0, 2.0, 3.0, 1.0,
        ]);
        // Semantically, A scales by (1,2,4) then translates by (1,2,3). In the book that
        // composition would read XMMatrixScaling(…) * XMMatrixTranslation(…); in glam the
        // product is written in reverse (point 3):
        assert_eq!(
            a,
            Mat4::from_translation(vec3(1.0, 2.0, 3.0)) * Mat4::from_scale(vec3(1.0, 2.0, 4.0))
        );
        // Translation sits in the last column (point 1); the last *row* is (0, 0, 0, 1).
        assert_eq!(a.col(3), vec4(1.0, 2.0, 3.0, 1.0));
        assert_eq!(a.row(3), vec4(0.0, 0.0, 0.0, 1.0));

        // C++: XMMATRIX B = XMMatrixIdentity();
        let b = Mat4::IDENTITY;

        // C++: XMMATRIX C = A * B;   → glam: B * A (point 3; identity, so C == A)
        let c = b * a;
        assert_eq!(c, a);

        // C++: XMMATRIX D = XMMatrixTranspose(A);
        let d = a.transpose();
        // C++ output rows of D (translation moved into the 4th *printed* column):
        //   1  0  0  1
        //   0  2  0  2
        //   0  0  4  3
        //   0  0  0  1
        assert_eq!(d.col(0), vec4(1.0, 0.0, 0.0, 1.0));
        assert_eq!(d.col(1), vec4(0.0, 2.0, 0.0, 2.0));
        assert_eq!(d.col(2), vec4(0.0, 0.0, 4.0, 3.0));
        assert_eq!(d.col(3), vec4(0.0, 0.0, 0.0, 1.0));

        // C++: XMVECTOR det = XMMatrixDeterminant(A);   — splatted (8, 8, 8, 8)
        // glam: a plain f32. (1 · 2 · 4 · 1 = 8; the translation doesn't affect it.)
        let det = a.determinant();
        assert_eq!(det, 8.0);

        // C++: XMMATRIX E = XMMatrixInverse(&det, A);
        // glam's inverse takes no determinant out-param — the book always passes the
        // determinant of A itself, which glam computes internally.
        let e = a.inverse();
        // C++ output rows of E: undo the scale (1, 1/2, 1/4), then the translation:
        //    1   0   0     0
        //    0   0.5 0     0
        //    0   0   0.25  0
        //   -1  -1  -0.75  1
        assert_eq!(e.col(0), vec4(1.0, 0.0, 0.0, 0.0));
        assert_eq!(e.col(1), vec4(0.0, 0.5, 0.0, 0.0));
        assert_eq!(e.col(2), vec4(0.0, 0.0, 0.25, 0.0));
        assert_eq!(e.col(3), vec4(-1.0, -1.0, -0.75, 1.0));

        // C++: XMMATRIX F = A * E;   → glam: E * A = identity
        let f = e * a;
        assert_eq!(f, Mat4::IDENTITY);
    }
}
