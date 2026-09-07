#+build windows
package common

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import win "core:sys/windows"
import "vendor:directx/d3d12"

// Opt-in: real D3D12 device + Windows Graphics Tools, no window or shader compiler.
// Run from the repository root with `just test-gpu`.
when #config(GRAPHICS_MEMORY_GPU_TESTS, false) {

@(private = "file")
gm_test_hr :: proc(t: ^testing.T, hr: d3d12.HRESULT, what: string) -> bool {
	return testing.expectf(t, hr >= 0, "%s: HRESULT %#x", what, u32(hr))
}

@(private = "file")
gm_test_wait :: proc(t: ^testing.T, fence: ^d3d12.IFence, value: u64) -> bool {
	event := win.CreateEventW(nil, false, false, nil)
	if !testing.expectf(t, event != nil, "CreateEventW failed: %v", win.GetLastError()) {return false}
	defer win.CloseHandle(event)
	if !gm_test_hr(t, fence->SetEventOnCompletion(value, event), "SetEventOnCompletion") {return false}
	result := win.WaitForSingleObject(event, 5000)
	if !testing.expectf(t, result == win.WAIT_OBJECT_0, "GPU fence wait failed/timed out: %v", result) {
		// Do not release resources or an event still referenced by a stalled queue.
		log.errorf("GPU fence wait failed/timed out (%v); terminating the test process", result)
		os.exit(1)
	}
	return true
}

// Replay the demo's ordering around a real GPU copy from an allocator constant.
// The marker completes before the gate: an early retirement signal MUST have completed
// when the CPU asks to recycle pages; a correctly ordered signal CANNOT have completed.
// The gate is released before waiting for GPU completion, including on early returns.
@(private = "file")
gm_test_retirement :: proc(t: ^testing.T, early_commit: bool, label: string) {
	debug: ^d3d12.IDebug1
	if !gm_test_hr(t, d3d12.GetDebugInterface(d3d12.IDebug1_UUID, ptr(&debug)), "D3D12 debug layer required") {return}
	debug->EnableDebugLayer()
	debug->Release()
	device: ^d3d12.IDevice5
	if !gm_test_hr(t, d3d12.CreateDevice(nil, ._11_0, d3d12.IDevice5_UUID, ptr(&device)), "CreateDevice") {return}
	defer device->Release()
	info: ^d3d12.IInfoQueue
	if !gm_test_hr(t, device->QueryInterface(d3d12.IInfoQueue_UUID, ptr(&info)), "Debug info queue required") {return}
	defer info->Release()
	defer {
		for i in 0 ..< info->GetNumStoredMessages() {
			size: d3d12.SIZE_T
			if !gm_test_hr(t, info->GetMessageA(i, nil, &size), "GetMessage size") {continue}
			data := make([]byte, int(size))
			message := (^d3d12.MESSAGE)(raw_data(data))
			if gm_test_hr(t, info->GetMessageA(i, message, &size), "GetMessage") {
				unexpected := message.Severity == .ERROR || message.Severity == .CORRUPTION ||
					(message.Severity == .WARNING && i32(message.ID) != 1328)
				testing.expectf(t, !unexpected,
					"%s: D3D12 %v: %s", label, message.Severity, message.pDescription)
			}
			delete(data)
		}
	}
	queue: ^d3d12.ICommandQueue
	queue_desc := d3d12.COMMAND_QUEUE_DESC{Type = .DIRECT}
	if !gm_test_hr(t, device->CreateCommandQueue(&queue_desc, d3d12.ICommandQueue_UUID, ptr(&queue)), "CreateCommandQueue") {return}
	defer queue->Release()
	allocator: ^d3d12.ICommandAllocator
	if !gm_test_hr(t, device->CreateCommandAllocator(.DIRECT, d3d12.ICommandAllocator_UUID, ptr(&allocator)), "CreateCommandAllocator") {return}
	defer allocator->Release()
	list: ^d3d12.IGraphicsCommandList
	if !gm_test_hr(t, device->CreateCommandList(0, .DIRECT, allocator, nil, d3d12.IGraphicsCommandList_UUID, ptr(&list)), "CreateCommandList") {return}
	defer list->Release()
	gate, marker: ^d3d12.IFence
	if !gm_test_hr(t, device->CreateFence(0, {}, d3d12.IFence_UUID, ptr(&gate)), "CreateFence gate") {return}
	defer gate->Release()
	if !gm_test_hr(t, device->CreateFence(0, {}, d3d12.IFence_UUID, ptr(&marker)), "CreateFence marker") {return}
	defer marker->Release()
	readback: ^d3d12.IResource
	heap := d3d12.HEAP_PROPERTIES{Type = .READBACK}
	desc := buffer_desc(4)
	if !gm_test_hr(t, device->CreateCommittedResource(&heap, {}, &desc, {.COPY_DEST}, nil,
		d3d12.IResource_UUID, ptr(&readback)), "Create readback") {return}
	defer readback->Release()
	gm: Graphics_Memory
	graphics_memory_init(&gm, device)
	defer graphics_memory_destroy(&gm)
	// Always unblock the queue and drain it BEFORE releasing any referenced resource.
	defer {
		if !gm_test_hr(t, gate->Signal(1), "Release gate during cleanup") ||
		   !gm_test_hr(t, queue->Signal(marker, 2), "Cleanup signal") ||
		   !gm_test_wait(t, marker, 2) {
			log.error("Cannot drain the GPU queue; terminating without releasing in-flight resources")
			os.exit(1)
		}
	}

	FIRST :: u32(0x11223344)
	SECOND :: u32(0xaabbccdd)
	a := allocate_constant(&gm, FIRST)
	// Test-local access to the page lets the GPU read these exact bytes without a shader.
	// GENERIC_READ on the upload page includes COPY_SOURCE.
	list->CopyBufferRegion(readback, 0, gm.active[0].resource, 0, size_of(FIRST))
	if !gm_test_hr(t, list->Close(), "Close copy list") {return}
	if early_commit {commit(&gm, queue)}
	if !gm_test_hr(t, queue->Signal(marker, 1), "Signal pre-gate marker") {return}
	if !gm_test_hr(t, queue->Wait(gate, 1), "Queue wait gate") {return}
	lists := [?]^d3d12.ICommandList{(^d3d12.ICommandList)(list)}
	queue->ExecuteCommandLists(len(lists), &lists[0])
	if !early_commit {commit(&gm, queue)}
	if !gm_test_wait(t, marker, 1) {return}

	// Simulate the next frame's retirement pass while the consumer is blocked.
	commit(&gm, queue)
	b := allocate_constant(&gm, SECOND)
	reused_early := a.gpu_address == b.gpu_address
	if !gm_test_hr(t, gate->Signal(1), "Release gate") {return}
	if !gm_test_wait(t, gm.fence, gm.fence_value) {return}
	mapped: rawptr
	if !gm_test_hr(t, readback->Map(0, nil, &mapped), "Map readback") {return}
	actual := (^u32)(mapped)^
	readback->Unmap(0, nil)
	log.infof("%s: early reuse=%v, GPU read=%#x, expected=%#x", label, reused_early, actual, FIRST)
	testing.expectf(t, !reused_early, "%s: upload address reused before consuming submission completed", label)
	testing.expectf(t, actual == FIRST, "%s: GPU read overwritten constant %#x (expected %#x)", label, actual, FIRST)

	// A fix that simply never recycles pages would hide the race but leak/grow memory.
	commit(&gm, queue)
	if !gm_test_wait(t, gm.fence, gm.fence_value) {return}
	commit(&gm, queue) // collect the now-completed pages as well
	c := allocate_constant(&gm, FIRST)
	testing.expectf(t, c.gpu_address == a.gpu_address, "%s: completed page should be reusable", label)
}

// These demos deliberately use a straight-line draw procedure with one submission and
// one commit. Read that real call-site order rather than hard-coding the correct order
// into the test. This is a focused source check, not an Odin parser: a changed procedure
// shape fails explicitly and requires updating the test's model during that refactor.
@(test)
graphics_memory_demo_retirement :: proc(t: ^testing.T) {
	paths := [?]string{
		"C7_Shapes/shapes_app.odin", "C7_Waves/waves_app.odin",
		"C8_LitShapes/lit_shapes_app.odin", "C8_LitWaves/lit_waves_app.odin",
		"C9_Crate/crate_app.odin", "C9_TexturedShapes/textured_shapes_app.odin", "C9_TexWaves/tex_waves_app.odin",
		"C10_BlendDemo/blend_demo_app.odin", "C11_Stenciling/stenciling_app.odin",
		"C12_BillboardsGS/billboard_app.odin", "C13_Blur/blur_app.odin", "C13_VecAddCS/vec_add_cs.odin",
		"C13_WavesCS/waves_cs_app.odin", "C14_BasicTessellation/basic_tessellation_app.odin",
		"C14_BezierPatch/bezier_patch_app.odin",
	}
	for path in paths {
		filename := strings.concatenate({"odin_port/", path})
		data, err := os.read_entire_file(filename, context.allocator)
		delete(filename)
		if !testing.expectf(t, err == nil, "%s: read from repository root: %v", path, err) {continue}
		defer delete(data)
		source := string(data)
		start := strings.index(source, "\ndraw :: proc(")
		if !testing.expectf(t, start >= 0, "%s: draw procedure not found", path) {continue}
		body := source[start:]
		end := strings.index(body, "\n}")
		if !testing.expectf(t, end >= 0, "%s: draw end not found", path) {continue}
		body = body[:end]
		// Anchoring the exact call lines avoids matching the C++ attribution comments.
		commit_call :: "\n\tcommon.commit(&app.linear_allocator, base.command_queue)"
		execute_call :: "\n\tbase.command_queue->ExecuteCommandLists("
		if !testing.expectf(t, strings.count(body, commit_call) == 1 && strings.count(body, execute_call) == 1,
			"%s: expected one commit and one submission; review the test model", path) {continue}
		gm_test_retirement(t, strings.index(body, commit_call) < strings.index(body, execute_call), path)
	}
}
}
