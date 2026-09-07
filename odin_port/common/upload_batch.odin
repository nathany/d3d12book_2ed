// PROVENANCE: partial port of DirectXTK12 (MIT license), NOT of the book's own code:
//
//  - Resource_Upload_Batch  <- ResourceUploadBatch (DirectXTK12 Src/ResourceUploadBatch.cpp),
//    reduced to what the book demos actually use: Begin on the direct queue, buffer
//    uploads, End. The C++ End() returns a std::future completed by a worker thread; this
//    port waits synchronously in upload_batch_end_and_wait — the demos block on the future
//    before their first draw anyway, so the observable behavior is identical (minus a few
//    milliseconds of init-time overlap).
//
//  - create_static_buffer  <- DirectX::CreateStaticBuffer (DirectXTK12 Src/BufferHelpers.cpp):
//    default-heap buffer created in COPY_DEST + an upload-heap intermediate holding the
//    data + CopyBufferRegion + a transition to the caller's final state. The intermediate
//    must outlive the GPU copy, so the batch tracks it (ResourceUploadBatch's
//    mTrackedObjects) and releases it after the wait.
package common

import "core:mem"
import win "core:sys/windows"
import d3d12 "vendor:directx/d3d12"

Resource_Upload_Batch :: struct {
	device:    ^d3d12.IDevice5, // borrowed, not owned
	cmd_alloc: ^d3d12.ICommandAllocator,
	cmd_list:  ^d3d12.IGraphicsCommandList6,
	tracked:   [dynamic]^d3d12.IResource, // upload intermediates kept alive until the wait
}

// C++: mUploadBatch->Begin(D3D12_COMMAND_LIST_TYPE_DIRECT) — the batch records on its own
// allocator/list, independent of the app's per-frame ones. (The book uploads on the
// direct queue for simplicity; a copy queue would be better for a real game.)
upload_batch_begin :: proc(batch: ^Resource_Upload_Batch, device: ^d3d12.IDevice5) {
	batch.device = device
	hr_panic(
		device->CreateCommandAllocator(
			.DIRECT,
			d3d12.ICommandAllocator_UUID,
			ptr(&batch.cmd_alloc),
		),
		"CreateCommandAllocator(upload batch)",
	)
	// Created open — ready to record copies, matching ResourceUploadBatch::Begin.
	hr_panic(
		device->CreateCommandList(
			0,
			.DIRECT,
			batch.cmd_alloc,
			nil,
			d3d12.IGraphicsCommandList6_UUID,
			ptr(&batch.cmd_list),
		),
		"CreateCommandList(upload batch)",
	)
}

// C++: DirectX::CreateStaticBuffer(device, uploadBatch, ptr, count, stride, afterState,
// &buffer) — see the provenance header. The caller owns (and Releases) out_buffer^.
create_static_buffer :: proc(
	batch: ^Resource_Upload_Batch,
	data: rawptr,
	count: int,
	stride: int,
	after_state: d3d12.RESOURCE_STATES,
	out_buffer: ^^d3d12.IResource,
) {
	size_in_bytes := u64(count) * u64(stride)
	desc := buffer_desc(size_in_bytes)

	// The GPU-resident (default heap) buffer, born in COPY_DEST.
	heap_default := d3d12.HEAP_PROPERTIES {
		Type = .DEFAULT,
	}
	hr_panic(
		batch.device->CreateCommittedResource(
			&heap_default,
			{},
			&desc,
			{.COPY_DEST},
			nil,
			d3d12.IResource_UUID,
			ptr(out_buffer),
		),
		"CreateCommittedResource(static buffer)",
	)

	// C++: resourceUpload.Upload(res, 0, &initData, 1) — an upload-heap intermediate the
	// CPU fills, then a recorded GPU copy into the default-heap buffer.
	upload: ^d3d12.IResource
	heap_upload := d3d12.HEAP_PROPERTIES {
		Type = .UPLOAD,
	}
	hr_panic(
		batch.device->CreateCommittedResource(
			&heap_upload,
			{},
			&desc,
			d3d12.RESOURCE_STATE_GENERIC_READ,
			nil,
			d3d12.IResource_UUID,
			ptr(&upload),
		),
		"CreateCommittedResource(upload intermediate)",
	)
	mapped: rawptr
	hr_panic(upload->Map(0, nil, &mapped), "Map(upload intermediate)")
	mem.copy(mapped, data, count * stride)
	upload->Unmap(0, nil)
	append(&batch.tracked, upload)

	batch.cmd_list->CopyBufferRegion(out_buffer^, 0, upload, 0, size_in_bytes)

	// C++: resourceUpload.Transition(res, D3D12_RESOURCE_STATE_COPY_DEST, afterState).
	barrier := transition_barrier(out_buffer^, {.COPY_DEST}, after_state)
	batch.cmd_list->ResourceBarrier(1, &barrier)
}

// C++: mUploadBatch->End(mCommandQueue.Get()) + result.wait(), fused (see the provenance
// header). Executes the recorded copies, blocks until the GPU finishes, then releases the
// intermediates and the batch's command objects. The batch is reusable after (Begin again).
upload_batch_end_and_wait :: proc(batch: ^Resource_Upload_Batch, queue: ^d3d12.ICommandQueue) {
	hr_panic(batch.cmd_list->Close(), "CommandList Close(upload batch)")
	cmd_lists := [?]^d3d12.ICommandList{(^d3d12.ICommandList)(batch.cmd_list)}
	queue->ExecuteCommandLists(len(cmd_lists), &cmd_lists[0])

	// One-shot fence wait (the C++ waits on the batch's own fence on a worker thread).
	fence: ^d3d12.IFence
	hr_panic(
		batch.device->CreateFence(0, {}, d3d12.IFence_UUID, ptr(&fence)),
		"CreateFence(upload batch)",
	)
	hr_panic(queue->Signal(fence, 1), "Signal(upload batch)")
	if fence->GetCompletedValue() < 1 {
		event := win.CreateEventW(nil, false, false, nil)
		hr_panic(fence->SetEventOnCompletion(1, event), "SetEventOnCompletion(upload batch)")
		win.WaitForSingleObject(event, win.INFINITE)
		win.CloseHandle(event)
	}
	fence->Release()

	// GPU is done with the copies — the intermediates can go.
	for res in batch.tracked {
		res->Release()
	}
	delete(batch.tracked)
	batch.cmd_list->Release()
	batch.cmd_alloc->Release()
	batch^ = {}
}
