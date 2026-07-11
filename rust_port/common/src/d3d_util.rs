//! The port's growing grab-bag of small D3D12 helpers — the book's `d3dUtil.h` +
//! `d3dx12.h` conveniences, added the first time a pattern repeats (per the porting guide:
//! don't port `d3dx12.h`, grow this organically).

use std::mem::ManuallyDrop;
use windows::Win32::Graphics::Direct3D12::{
    D3D12_RESOURCE_BARRIER, D3D12_RESOURCE_BARRIER_0, D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
    D3D12_RESOURCE_BARRIER_FLAG_NONE, D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
    D3D12_RESOURCE_STATES, D3D12_RESOURCE_TRANSITION_BARRIER, ID3D12Resource,
};
use windows::Win32::UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW};
use windows::core::{HSTRING, w};

/// C++: `CD3DX12_RESOURCE_BARRIER::Transition(resource, before, after)`.
///
/// The returned barrier BORROWS `resource` — it holds the raw interface pointer without
/// adding a reference (`ManuallyDrop` suppresses the release), exactly like the C++ helper.
/// The caller's `resource` must stay alive until the barrier has been passed to
/// `ResourceBarrier`, which the borrow in the signature enforces for the typical
/// build-and-submit-in-one-expression call site.
pub fn transition_barrier(
    resource: &ID3D12Resource,
    state_before: D3D12_RESOURCE_STATES,
    state_after: D3D12_RESOURCE_STATES,
) -> D3D12_RESOURCE_BARRIER {
    D3D12_RESOURCE_BARRIER {
        Type: D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
        Flags: D3D12_RESOURCE_BARRIER_FLAG_NONE,
        Anonymous: D3D12_RESOURCE_BARRIER_0 {
            Transition: ManuallyDrop::new(D3D12_RESOURCE_TRANSITION_BARRIER {
                // SAFETY: transmute_copy duplicates the interface pointer WITHOUT AddRef;
                // paired with ManuallyDrop (no Release), the net refcount change is zero —
                // a borrow in struct form. Sound because the barrier is consumed by
                // ResourceBarrier while `resource` is still borrowed.
                pResource: unsafe { std::mem::transmute_copy(resource) },
                StateBefore: state_before,
                StateAfter: state_after,
                Subresource: D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
            }),
        },
    }
}

/// Fatal-error reporting, both channels (port convention — see the guide):
/// stderr for consoles/CI, a message box for a human running the windowed app
/// (the book's `MessageBox(0, L"…FAILED", 0, 0)` style, centralized).
pub fn report_error(e: &windows::core::Error) {
    eprintln!("fatal error: {e}");
    let text = HSTRING::from(e.to_string());
    // SAFETY: FFI; None parent because the main window may not exist (yet, or anymore).
    unsafe { MessageBoxW(None, &text, w!("Error"), MB_OK | MB_ICONERROR) };
}
