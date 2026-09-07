// PROVENANCE: reduced port of DirectXTK12 (MIT license) **GraphicsMemory** — the paged
// linear upload allocator (Src/GraphicsMemory.cpp + LinearAllocator.cpp) — NOT the book's
// own code. The C++ demos reach it as `mLinearAllocator` on D3DApp / the
// `GraphicsMemory::Get(device)` singleton.
//
// What survives the reduction (the contract the demos rely on):
//  - allocate_constant(T): copy T into a persistently-mapped upload page at a 256-byte
//    aligned offset and return its GPU virtual address, valid until the frame's commands
//    finish on the GPU.
//  - commit(queue): call AFTER ExecuteCommandLists submits every consumer of the active
//    pages to this same queue. Its signal then follows those consumers; pages can only
//    be recycled after that signal completes. Allocation/commit is single-threaded.
//    This deliberately differs from the book's commit-before-submit call order:
//    DirectXTK12's GraphicsResource retains its page and defers retirement while handles
//    exist. Odin's reduced handle only stores an address, so queue order supplies that
//    lifetime guarantee. Keeping the handle variable alive does not retain the page.
//  - get_statistics(): the numbers behind the ImGui "GraphicsMemoryStatistics" panel.
//
// What's dropped: pow2 size-bucketed allocator pools, multi-device singleton table,
// GraphicsResource RAII handles. Returned addresses remain valid through the consuming
// submission only when callers follow the submit-then-commit contract above.
package common

import "core:mem"
import win "core:sys/windows"
import d3d12 "vendor:directx/d3d12"

// One upload-heap page, persistently mapped. DXTK's minimum page size is 64 KiB; a larger
// single allocation gets its own exact-size page.
@(private = "file")
GM_PAGE_SIZE :: 64 * 1024

@(private = "file")
Gm_Page :: struct {
	resource:    ^d3d12.IResource,
	mapped:      [^]byte,
	size:        u64,
	offset:      u64,
	fence_value: u64, // set when the page's frame is committed
}

// C++: DirectX::GraphicsResource, reduced to the one field the demos use (GpuAddress()).
Graphics_Resource :: struct {
	gpu_address: d3d12.GPU_VIRTUAL_ADDRESS,
}

// C++: DirectX::GraphicsMemoryStatistics (the fields the demos display).
Graphics_Memory_Statistics :: struct {
	committed_memory: u64, // bytes in-flight on the GPU
	total_memory:     u64, // total bytes in all pages (in use or recycled)
	total_pages:      u64,
}

Graphics_Memory :: struct {
	device:      ^d3d12.IDevice5, // borrowed
	fence:       ^d3d12.IFence,
	fence_value: u64,
	active:      [dynamic]^Gm_Page, // being filled this frame
	in_flight:   [dynamic]^Gm_Page, // committed, awaiting their fence
	free_pages:  [dynamic]^Gm_Page,
}

// C++: GraphicsMemory(device) — page creation is lazy, so demos that never allocate
// (ch 4/6) pay only for the fence.
graphics_memory_init :: proc(gm: ^Graphics_Memory, device: ^d3d12.IDevice5) {
	gm.device = device
	hr_panic(
		device->CreateFence(0, {}, d3d12.IFence_UUID, ptr(&gm.fence)),
		"CreateFence(GraphicsMemory)",
	)
}

// C++: ~GraphicsMemory. Call after the queue is flushed (d3d_app_shutdown does).
graphics_memory_destroy :: proc(gm: ^Graphics_Memory) {
	destroy_pages :: proc(pages: ^[dynamic]^Gm_Page) {
		for page in pages {
			page.resource->Unmap(0, nil)
			page.resource->Release()
			free(page)
		}
		delete(pages^)
	}
	destroy_pages(&gm.active)
	destroy_pages(&gm.in_flight)
	destroy_pages(&gm.free_pages)
	if gm.fence != nil {gm.fence->Release();gm.fence = nil}
}

// C++: GraphicsMemory::AllocateConstant<T>(data) — 256-byte aligned copy into the current
// page; the returned GPU address is valid until this frame's commands retire.
allocate_constant :: proc(gm: ^Graphics_Memory, data: $T) -> Graphics_Resource {
	data := data
	size := u64(calc_constant_buffer_byte_size(size_of(T)))

	page := acquire_page(gm, size)
	offset := page.offset
	page.offset += size

	mem.copy(&page.mapped[offset], &data, size_of(T))

	return {gpu_address = page.resource->GetGPUVirtualAddress() + offset}
}

// C++: GraphicsMemory::Commit(queue). Odin callers must first submit all active-page
// consumers to this queue. Retire completed pages, then fence this submission's pages.
commit :: proc(gm: ^Graphics_Memory, queue: ^d3d12.ICommandQueue) {
	// Recycle in-flight pages the GPU is done with (compact in place).
	completed := gm.fence->GetCompletedValue()
	kept := 0
	for page in gm.in_flight {
		if page.fence_value <= completed {
			page.offset = 0
			page.fence_value = 0
			append(&gm.free_pages, page)
		} else {
			gm.in_flight[kept] = page
			kept += 1
		}
	}
	resize(&gm.in_flight, kept)

	// This frame's pages go in flight behind a new fence point.
	gm.fence_value += 1
	for page in gm.active {
		page.fence_value = gm.fence_value
		append(&gm.in_flight, page)
	}
	clear(&gm.active)
	hr_panic(queue->Signal(gm.fence, gm.fence_value), "Signal(GraphicsMemory)")
}

// C++: GraphicsMemory::GetStatistics().
get_statistics :: proc(gm: ^Graphics_Memory) -> Graphics_Memory_Statistics {
	stats: Graphics_Memory_Statistics
	for page in gm.in_flight {
		stats.committed_memory += page.size
	}
	stats.total_memory = stats.committed_memory
	for page in gm.active {stats.total_memory += page.size}
	for page in gm.free_pages {stats.total_memory += page.size}
	stats.total_pages = u64(len(gm.active) + len(gm.in_flight) + len(gm.free_pages))
	return stats
}

// Find an active page with room, else reuse a free page, else create one.
@(private = "file")
acquire_page :: proc(gm: ^Graphics_Memory, size: u64) -> ^Gm_Page {
	for page in gm.active {
		if page.offset + size <= page.size {
			return page
		}
	}
	for page, i in gm.free_pages {
		if size <= page.size {
			unordered_remove(&gm.free_pages, i)
			append(&gm.active, page)
			return page
		}
	}

	// New page (lazy; exact-size for oversized requests, like DXTK).
	page := new(Gm_Page)
	page.size = max(size, GM_PAGE_SIZE)
	heap_upload := d3d12.HEAP_PROPERTIES {
		Type = .UPLOAD,
	}
	desc := buffer_desc(page.size)
	hr_panic(
		gm.device->CreateCommittedResource(
			&heap_upload,
			{},
			&desc,
			d3d12.RESOURCE_STATE_GENERIC_READ,
			nil,
			d3d12.IResource_UUID,
			ptr(&page.resource),
		),
		"CreateCommittedResource(GraphicsMemory page)",
	)
	hr_panic(page.resource->Map(0, nil, (^rawptr)(&page.mapped)), "Map(GraphicsMemory page)")
	append(&gm.active, page)
	return page
}
