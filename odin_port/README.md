# odin_port

Odin reference implementation of the demos from Luna's *Introduction to 3D Game Programming
with DirectX 12* (2nd ed.). Chapter-by-chapter porting notes live in
[`../Frank Luna ODIN_PORTING_GUIDE.md`](../Frank%20Luna%20ODIN_PORTING_GUIDE.md).

## Layout

Directories mirror the book's `Demos/` folders (one Odin package per demo); files within a
package mirror the demo's `.cpp` files. Shared code lives in its own packages
(`d3d_math`, `test_util`, later a `common` equivalent).

## Running

```
odin test odin_port/C1_XMVECTOR       # chapters 1–3 are math-only, ported as tests that
odin test odin_port/C2_XMMATRIX       # assert values captured from the C++ demos' output
odin test odin_port/C3_TRANSFORMATIONS
```

## The convention decision (differs from `rust_port/`!)

This port keeps **the book's row-vector convention**, via
`Mat4 :: #row_major matrix[4, 4]f32` in `d3d_math` — byte-identical to `XMFLOAT4X4`. As a
result, matrix literals are typed exactly as the book prints them, concatenation reads
left-to-right exactly as the book writes it (`S * R * T`), points transform as `v * M`, and
the transpose-before-CB-upload line survives unchanged. Contrast with `rust_port/`, where
glam's column-vector convention reverses every matrix product. The view/projection/rotation
*builders* are hand-rolled in `d3d_math` from the book's printed forms — `core:math/linalg`'s
builders are GL-flavored column-vector and must not be mixed in (its convention-agnostic
operations — `dot`, `cross`, `normalize`, `inverse`, `transpose`, element-wise math — are
used freely).
