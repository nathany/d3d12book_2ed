// The port's growing grab-bag of small helpers — the book's `d3dUtil.h` + `d3dx12.h`
// conveniences, added the first time a pattern repeats (per the porting guide: don't port
// d3dx12.h, grow this organically).
package common

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import d3d12 "vendor:directx/d3d12"
import dxc "vendor:directx/dxc"
import dxgi "vendor:directx/dxgi"

// Fatal-error reporting, both channels (port convention — see the guides): stderr for
// consoles/CI, a message box for a human running the windowed app. (Duplicated from
// APPENDIX_A, which stays self-contained by design.)
report_error :: proc(what: string) {
	fmt.eprintfln("fatal error: %s", what)
	text := win.utf8_to_wstring(what)
	win.MessageBoxW(nil, text, win.L("Error"), win.MB_OK | win.MB_ICONERROR)
}

// C++: ThrowIfFailed(hr) + the DxException catch in WinMain, fused. The guide's day-one
// `hr_panic`: #caller_location gives free file:line in the report — nicer than the C++.
hr_panic :: proc(hr: d3d12.HRESULT, what: string, loc := #caller_location) {
	if hr >= 0 {
		return
	}
	report_error(fmt.tprintf("%s failed with HRESULT 0x%8x at %v", what, u32(hr), loc))
	os.exit(1)
}

// C++: CD3DX12_RESOURCE_BARRIER::Transition(resource, before, after).
// Plain data — the barrier borrows the resource pointer (no ref counting), same as C++.
transition_barrier :: proc(
	resource: ^d3d12.IResource,
	before, after: d3d12.RESOURCE_STATES,
) -> d3d12.RESOURCE_BARRIER {
	barrier := d3d12.RESOURCE_BARRIER {
		Type  = .TRANSITION,
		Flags = {},
	}
	barrier.Transition = {
		pResource   = resource,
		StateBefore = before,
		StateAfter  = after,
		Subresource = d3d12.RESOURCE_BARRIER_ALL_SUBRESOURCES,
	}
	return barrier
}

// C++: CD3DX12_RESOURCE_BARRIER::UAV. Orders unordered-access reads/writes without
// changing the resource state.
uav_barrier :: proc(resource: ^d3d12.IResource) -> d3d12.RESOURCE_BARRIER {
	barrier := d3d12.RESOURCE_BARRIER{Type = .UAV}
	barrier.UAV = {pResource = resource}
	return barrier
}

// Convenience for COM out-params: `ptr(&obj)` in place of C++ IID_PPV_ARGS's second half.
ptr :: proc(p: ^^$T) -> ^rawptr {
	return (^rawptr)(p)
}

// For "system" callbacks (WndProc, InfoQueue1) that need Odin features (fmt, allocators):
// they have no context; restore the default one.
default_context :: proc "contextless" () -> runtime.Context {
	return runtime.default_context()
}

// C++: d3dUtil::CalcConstantBufferByteSize(byteSize).
calc_constant_buffer_byte_size :: proc(byte_size: u32) -> u32 {
	// Constant buffers must be a multiple of the minimum hardware
	// allocation size (usually 256 bytes).  So round up to nearest
	// multiple of 256.  We do this by adding 255 and then masking off
	// the lower 2 bytes which store all bits < 256.
	// Example: Suppose byteSize = 300.
	// (300 + 255) & ~255
	// 555 & ~255
	// 0x022B & ~0x00ff
	// 0x022B & 0xff00
	// 0x0200
	// 512
	return (byte_size + 255) & ~u32(255) // D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT
}

// C++: CD3DX12_RESOURCE_DESC::Buffer(size) — buffers are 1D, ROW_MAJOR, format UNKNOWN.
buffer_desc :: proc(size_in_bytes: u64) -> d3d12.RESOURCE_DESC {
	return {
		Dimension = .BUFFER,
		Alignment = 0,
		Width = size_in_bytes,
		Height = 1,
		DepthOrArraySize = 1,
		MipLevels = 1,
		Format = .UNKNOWN,
		SampleDesc = {Count = 1, Quality = 0},
		Layout = .ROW_MAJOR,
		Flags = {},
	}
}

// C++: d3dUtil::ByteCodeFromBlob(shader).
byte_code_from_blob :: proc(shader: ^dxc.IBlob) -> d3d12.SHADER_BYTECODE {
	return {shader->GetBufferPointer(), shader->GetBufferSize()}
}

// C++: CD3DX12_RASTERIZER_DESC(D3D12_DEFAULT) / CD3DX12_BLEND_DESC(D3D12_DEFAULT) /
// CD3DX12_DEPTH_STENCIL_DESC(D3D12_DEFAULT) — d3dx12.h's defaults, spelled out once.
DEFAULT_RASTERIZER_DESC :: d3d12.RASTERIZER_DESC {
	FillMode              = .SOLID,
	CullMode              = .BACK,
	FrontCounterClockwise = false,
	DepthBias             = 0,
	DepthBiasClamp        = 0,
	SlopeScaledDepthBias  = 0,
	DepthClipEnable       = true,
	MultisampleEnable     = false,
	AntialiasedLineEnable = false,
	ForcedSampleCount     = 0,
	ConservativeRaster    = .OFF,
}

@(private)
DEFAULT_RENDER_TARGET_BLEND_DESC :: d3d12.RENDER_TARGET_BLEND_DESC {
	BlendEnable           = false,
	LogicOpEnable         = false,
	SrcBlend              = .ONE,
	DestBlend             = .ZERO,
	BlendOp               = .ADD,
	SrcBlendAlpha         = .ONE,
	DestBlendAlpha        = .ZERO,
	BlendOpAlpha          = .ADD,
	LogicOp               = .NOOP,
	RenderTargetWriteMask = 0x0F, // D3D12_COLOR_WRITE_ENABLE_ALL
}

DEFAULT_BLEND_DESC :: d3d12.BLEND_DESC {
	AlphaToCoverageEnable  = false,
	IndependentBlendEnable = false,
	RenderTarget           = {0 ..= 7 = DEFAULT_RENDER_TARGET_BLEND_DESC},
}

DEFAULT_DEPTH_STENCIL_DESC :: d3d12.DEPTH_STENCIL_DESC {
	DepthEnable      = true,
	DepthWriteMask   = .ALL,
	DepthFunc        = .LESS,
	StencilEnable    = false,
	StencilReadMask  = 0xFF, // D3D12_DEFAULT_STENCIL_READ_MASK
	StencilWriteMask = 0xFF,
	FrontFace        = {StencilFailOp = .KEEP, StencilDepthFailOp = .KEEP, StencilPassOp = .KEEP, StencilFunc = .ALWAYS},
	BackFace         = {StencilFailOp = .KEEP, StencilDepthFailOp = .KEEP, StencilPassOp = .KEEP, StencilFunc = .ALWAYS},
}

// C++: d3dUtil::InitDefaultPso — helper function for most of the common case code to fill
// out PSO description. Modify the return value as needed to customize.
init_default_pso :: proc(
	rtv_format: dxgi.FORMAT,
	dsv_format: dxgi.FORMAT,
	input_layout: []d3d12.INPUT_ELEMENT_DESC,
	root_sig: ^d3d12.IRootSignature,
	vertex_shader: ^dxc.IBlob,
	pixel_shader: ^dxc.IBlob,
) -> d3d12.GRAPHICS_PIPELINE_STATE_DESC {
	pso_desc: d3d12.GRAPHICS_PIPELINE_STATE_DESC

	pso_desc.InputLayout = {raw_data(input_layout), u32(len(input_layout))}
	pso_desc.pRootSignature = root_sig
	pso_desc.VS = byte_code_from_blob(vertex_shader)
	pso_desc.PS = byte_code_from_blob(pixel_shader)

	pso_desc.RasterizerState = DEFAULT_RASTERIZER_DESC
	pso_desc.BlendState = DEFAULT_BLEND_DESC
	pso_desc.DepthStencilState = DEFAULT_DEPTH_STENCIL_DESC
	pso_desc.SampleMask = max(u32)
	pso_desc.PrimitiveTopologyType = .TRIANGLE
	pso_desc.NumRenderTargets = 1
	pso_desc.RTVFormats[0] = rtv_format
	pso_desc.SampleDesc = {Count = 1, Quality = 0}
	pso_desc.DSVFormat = dsv_format

	return pso_desc
}

// The C++ function-local statics: one DXC instance for the whole process (never
// Released, like the C++ — DXC objects are not D3D/DXGI objects, so they don't appear in
// the shutdown leak report).
@(private) dxc_utils: ^dxc.IUtils
@(private) dxc_compiler: ^dxc.ICompiler3
@(private) dxc_include_handler: ^dxc.IIncludeHandler

// C++: d3dUtil::CompileShader(filename, compileArgs) — DXC, for shader model 6.0+.
// compile_args is exactly what you would pass to the dxc command line, e.g.
// {"-E", "VS", "-T", "vs_6_6"}; helper strings from dxcapi.h are in vendor's dxc package
// (dxc.ARG_DEBUG = "-Zi", dxc.ARG_SKIP_OPTIMIZATIONS = "-Od", ...).
// See "HLSL Compiler | Michael Dougherty | DirectX Developer Day"
// https://www.youtube.com/watch?v=tyyKeTsdtmo
// The caller owns (and Releases) the returned DXIL blob.
compile_shader :: proc(filename: string, compile_args: []string) -> ^dxc.IBlob {
	if !os.exists(filename) {
		// C++: OutputDebugString + MessageBox; report_error covers both channels.
		report_error(fmt.tprintf("%s not found.", filename))
		os.exit(1)
	}

	// Only need one of these.
	if dxc_compiler == nil {
		hr_panic(
			dxc.CreateInstance(dxc.Utils_CLSID, dxc.IUtils_UUID, ptr(&dxc_utils)),
			"DxcCreateInstance(Utils)",
		)
		hr_panic(
			dxc.CreateInstance(dxc.Compiler_CLSID, dxc.ICompiler3_UUID, ptr(&dxc_compiler)),
			"DxcCreateInstance(Compiler)",
		)
		hr_panic(
			dxc_utils->CreateDefaultIncludeHandler(&dxc_include_handler),
			"CreateDefaultIncludeHandler",
		)
	}

	// Use IDxcUtils to load the text file.
	code_page: u32 = dxc.CP_UTF8
	source_blob: ^dxc.IBlobEncoding
	hr_panic(
		dxc_utils->LoadFile(win.utf8_to_wstring(filename), &code_page, &source_blob),
		"IDxcUtils::LoadFile",
	)
	defer source_blob->Release()

	// Create a DxcBuffer buffer to the source code.
	source_buffer := dxc.Buffer {
		Ptr      = source_blob->GetBufferPointer(),
		Size     = source_blob->GetBufferSize(),
		Encoding = 0,
	}

	wargs := make([]win.wstring, len(compile_args), context.temp_allocator)
	for arg, i in compile_args {
		wargs[i] = win.utf8_to_wstring(arg)
	}

	result: ^dxc.IResult
	hr := dxc_compiler->Compile(
		&source_buffer, //          source code
		raw_data(wargs), //         arguments
		u32(len(wargs)), //         argument count
		dxc_include_handler, //     include handler
		dxc.IResult_UUID,
		ptr(&result), //            output
	)
	// Odin: validate the method result before touching its output. The book defers
	// this check, but a failed Compile call need not return an IResult at all.
	hr_panic(hr, "IDxcCompiler3::Compile")
	if result == nil {
		report_error("IDxcCompiler3::Compile succeeded without returning a result")
		os.exit(1)
	}
	defer result->Release()
	compile_status: dxc.HRESULT
	hr_panic(result->GetStatus(&compile_status), "IDxcResult::GetStatus")

	// Get errors and output them if any.
	error_msgs: ^dxc.IBlobUtf8
	hr_panic(result->GetOutput(.ERRORS, dxc.IBlobUtf8_UUID, ptr(&error_msgs), nil), "GetOutput(ERRORS)")
	if error_msgs != nil {
		defer error_msgs->Release()
		if error_msgs->GetStringLength() > 0 {
			// Replace the hlsl.hlsl placeholder in the error string with the shader
			// filename (DXC doesn't know the file name; we compiled from a memory buffer).
			error_text, _ := strings.replace_all(
				string(error_msgs->GetStringPointer()),
				"hlsl.hlsl",
				filename,
				context.temp_allocator,
			)
			report_error(error_text) // C++: OutputDebugString + ThrowIfFailed(E_FAIL)
			os.exit(1)
		}
	}
	hr_panic(compile_status, "Shader compilation")

	// Get the DX intermediate language, which the GPU driver will translate
	// into native GPU code.
	dxil: ^dxc.IBlob
	hr_panic(result->GetOutput(.OBJECT, dxc.IBlob_UUID, ptr(&dxil), nil), "GetOutput(OBJECT)")
	if dxil == nil {
		report_error("Shader compilation succeeded without returning DXIL")
		os.exit(1)
	}

	when ODIN_DEBUG {
		// Write PDB data for PIX debugging (debug args add -Zi, which produces one).
		PDB_DIRECTORY :: "HLSL PDB"
		if !os.exists(PDB_DIRECTORY) {
			os.make_directory(PDB_DIRECTORY)
		}

		pdb_data: ^dxc.IBlob
		pdb_path_from_compiler: ^dxc.IBlobUtf16
		if result->GetOutput(.PDB, dxc.IBlob_UUID, ptr(&pdb_data), &pdb_path_from_compiler) >=
		   0 {
			// PDB output is optional (for example, without -Zi).
			defer {
				if pdb_data != nil {pdb_data->Release()}
				if pdb_path_from_compiler != nil {pdb_path_from_compiler->Release()}
			}
			if pdb_data == nil || pdb_path_from_compiler == nil {return dxil}
			pdb_name_utf16 := ([^]u16)(pdb_path_from_compiler->GetStringPointer())
			pdb_name, _ := win.utf16_to_utf8(
				pdb_name_utf16[:pdb_path_from_compiler->GetStringLength()],
				context.temp_allocator,
			)
			pdb_bytes := ([^]byte)(pdb_data->GetBufferPointer())[:pdb_data->GetBufferSize()]
			if err := os.write_entire_file(fmt.tprintf("%s/%s", PDB_DIRECTORY, pdb_name), pdb_bytes);
			   err != nil {
				fmt.eprintfln("could not write shader PDB %s: %v", pdb_name, err)
			}
		}
	}

	// Return the data blob containing the DXIL code.
	return dxil
}
