set shell := ["bash", "-uc"]
set default-list := true

app_packages := "APPENDIX_A C4_Init_Direct3D C6_Box C6_BoxGrid C7_Shapes C7_Waves C8_LitShapes C8_LitWaves C9_Crate C9_TexturedShapes C9_TexWaves C10_BlendDemo C11_Stenciling C12_BillboardsGS C13_Blur C13_VecAddCS C13_WavesCS C14_BasicTessellation C14_BezierPatch"
test_packages := "C1_XMVECTOR C2_XMMATRIX C3_TRANSFORMATIONS dds"
support_packages := "common d3d_math test_util"

# List runnable Odin examples.
examples:
    @printf '%s\n' {{app_packages}}

# Run an example with debug validation and allocation tracking enabled.
run example:
    odin run "odin_port/{{example}}" -debug

# Run an example without ODIN_DEBUG instrumentation.
run-release example:
    odin run "odin_port/{{example}}"

# Run a math or parser test package.
test package:
    odin test "odin_port/{{package}}"

# Type-check a runnable example in release and debug configurations.
check example:
    odin check "odin_port/{{example}}" -strict-style -warnings-as-errors
    odin check "odin_port/{{example}}" -debug -strict-style -warnings-as-errors

# Type-check a test-only or support package in release and debug configurations.
check-test package:
    odin check "odin_port/{{package}}" -no-entry-point -strict-style -warnings-as-errors
    odin check "odin_port/{{package}}" -no-entry-point -debug -strict-style -warnings-as-errors

# Type-check every Odin example and support package.
check-all:
    set -e; for package in {{app_packages}}; do odin check "odin_port/$package" -strict-style -warnings-as-errors; odin check "odin_port/$package" -debug -strict-style -warnings-as-errors; done
    set -e; for package in {{test_packages}} {{support_packages}}; do odin check "odin_port/$package" -no-entry-point -strict-style -warnings-as-errors; odin check "odin_port/$package" -no-entry-point -debug -strict-style -warnings-as-errors; done

# Run all math and DDS parser tests.
test-all:
    set -e; for package in {{test_packages}}; do odin test "odin_port/$package"; done

# Opt-in D3D12 upload-lifetime regression; requires Windows Graphics Tools and a D3D12 device.
test-gpu:
    odin test odin_port/common -debug -strict-style -warnings-as-errors -define:GRAPHICS_MEMORY_GPU_TESTS=true -define:ODIN_TEST_THREADS=1

# Build an example with AddressSanitizer into the session temp directory.
build-asan example:
    out_dir="${TMPDIR:-${TEMP:-/tmp}}/d3d12book_2ed"; mkdir -p "$out_dir"; odin build "odin_port/{{example}}" -debug -sanitize:address -out:"$out_dir/{{example}}-asan.exe"; printf 'Built %s\n' "$out_dir/{{example}}-asan.exe"

# Run an example under AddressSanitizer.
run-asan example:
    odin run "odin_port/{{example}}" -debug -sanitize:address

# Run the full non-interactive validation suite.
validate: check-all test-all
