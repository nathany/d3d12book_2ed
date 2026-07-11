//! Partial port of `Common/DescriptorUtil.h/.cpp` (Frank Luna).
//!
//! Chapter 4 needs only the plain [`DescriptorHeap`] (RTV + DSV). The book's
//! `CbvSrvUavHeap` (bindless free-index allocator) and `SamplerHeap` arrive with the first
//! demos that bind shader resources; both are C++ singletons — the port will pass them
//! explicitly instead. The `CreateDsv`/`CreateSrv2d`/… helper functions get ported alongside
//! the chapters that first call them.

use windows::Win32::Graphics::Direct3D12::{
    D3D12_CPU_DESCRIPTOR_HANDLE, D3D12_DESCRIPTOR_HEAP_DESC, D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
    D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE, D3D12_DESCRIPTOR_HEAP_TYPE,
    D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER,
    D3D12_GPU_DESCRIPTOR_HANDLE, ID3D12DescriptorHeap, ID3D12Device5,
};
use windows::core::Result;

/// A descriptor heap plus the handle arithmetic the book wraps in
/// `CpuHandle(i)`/`GpuHandle(i)`: `heap_start + index * increment_size`.
pub struct DescriptorHeap {
    heap: ID3D12DescriptorHeap,
    descriptor_size: u32,
}

impl DescriptorHeap {
    /// C++: `DescriptorHeap::Init(device, type, capacity)`.
    pub fn new(
        device: &ID3D12Device5,
        heap_type: D3D12_DESCRIPTOR_HEAP_TYPE,
        capacity: u32,
    ) -> Result<Self> {
        // CBV/SRV/UAV and sampler heaps are the shader-visible kinds; RTV/DSV heaps are
        // CPU-only and must not set the flag.
        let shader_visible = heap_type == D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV
            || heap_type == D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER;
        let desc = D3D12_DESCRIPTOR_HEAP_DESC {
            Type: heap_type,
            NumDescriptors: capacity,
            Flags: if shader_visible {
                D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE
            } else {
                D3D12_DESCRIPTOR_HEAP_FLAG_NONE
            },
            NodeMask: 0,
        };
        // SAFETY: desc is fully initialized and only read during the call.
        let heap: ID3D12DescriptorHeap = unsafe { device.CreateDescriptorHeap(&desc) }?;
        // SAFETY: FFI with no preconditions; per-type constant for this device.
        let descriptor_size = unsafe { device.GetDescriptorHandleIncrementSize(heap_type) };
        Ok(Self {
            heap,
            descriptor_size,
        })
    }

    /// C++: `GetD3dHeap()`.
    pub fn d3d_heap(&self) -> &ID3D12DescriptorHeap {
        &self.heap
    }

    /// C++: `CpuHandle(index)`.
    pub fn cpu_handle(&self, index: u32) -> D3D12_CPU_DESCRIPTOR_HANDLE {
        // SAFETY: FFI with no preconditions.
        let start = unsafe { self.heap.GetCPUDescriptorHandleForHeapStart() };
        D3D12_CPU_DESCRIPTOR_HANDLE {
            ptr: start.ptr + index as usize * self.descriptor_size as usize,
        }
    }

    /// C++: `GpuHandle(index)`. Only valid on shader-visible heaps.
    pub fn gpu_handle(&self, index: u32) -> D3D12_GPU_DESCRIPTOR_HANDLE {
        // SAFETY: FFI with no preconditions.
        let start = unsafe { self.heap.GetGPUDescriptorHandleForHeapStart() };
        D3D12_GPU_DESCRIPTOR_HANDLE {
            ptr: start.ptr + index as u64 * self.descriptor_size as u64,
        }
    }
}
