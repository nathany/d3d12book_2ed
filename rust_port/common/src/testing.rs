//! Tiny float-comparison helpers for the math-chapter tests.
//!
//! `std` has no approximate float assertions — `assert_eq!` compares exactly, and the only
//! related std item is the [`f32::EPSILON`] constant. The ecosystem standard is the `approx`
//! crate (glam integrates with it behind an `approx` feature), and glam ships its own
//! `abs_diff_eq` methods on every vector type. For this project's needs — asserting ported
//! demo values against numbers captured from the C++ demos' output, which `cout` rounds to
//! 6 significant digits — a plain absolute-difference check is enough, wrapped so failures
//! print both values.

use glam::{Vec3, Vec4};

/// Panics unless `|actual - expected| <= eps`.
///
/// Pick `eps` from where the expected value came from: values transcribed from C++ `cout`
/// output carry up to half a unit of error in the 6th significant digit (e.g. `3.74166`
/// → `eps = 1e-5`); values that are exact in the output can use [`assert_eq!`] instead.
#[track_caller]
pub fn assert_close(actual: f32, expected: f32, eps: f32) {
    assert!(
        (actual - expected).abs() <= eps,
        "assert_close: actual {actual} vs expected {expected} (eps {eps})"
    );
}

/// Component-wise [`assert_close`] for [`Vec3`], via glam's `abs_diff_eq`.
#[track_caller]
pub fn assert_close3(actual: Vec3, expected: Vec3, eps: f32) {
    assert!(
        actual.abs_diff_eq(expected, eps),
        "assert_close3: actual {actual} vs expected {expected} (eps {eps})"
    );
}

/// Component-wise [`assert_close`] for [`Vec4`], via glam's `abs_diff_eq`.
#[track_caller]
pub fn assert_close4(actual: Vec4, expected: Vec4, eps: f32) {
    assert!(
        actual.abs_diff_eq(expected, eps),
        "assert_close4: actual {actual} vs expected {expected} (eps {eps})"
    );
}
