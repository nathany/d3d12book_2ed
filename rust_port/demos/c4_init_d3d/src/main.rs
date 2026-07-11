//! Port of `Demos/C4_Init Direct3D` — chapter 4's initialization demo: clear the screen to
//! LightSteelBlue every frame; FPS/mspf in the title bar; resize must survive repeated abuse
//! (the chapter's real test — it exercises the `OnResize`/`ResizeBuffers` back-buffer trap).
//!
//! **Not yet ported from the C++ demo:** the ImGui overlay (Options panel, video-memory
//! stats) and with it the CbvSrvUav descriptor heap — that's the next step, where imgui-rs
//! gets its trial. The clear-and-present core below needs neither, nor any shader, which is
//! why this demo has no DXC/Agility dependency at all.

use common::d3d_app::{D3DApp, D3DAppHandler, SWAP_CHAIN_BUFFER_COUNT, run};
use common::d3d_util::{report_error, transition_barrier};
use windows::Win32::Graphics::Direct3D12::{
    D3D12_CLEAR_FLAG_DEPTH, D3D12_CLEAR_FLAG_STENCIL, D3D12_RESOURCE_STATE_PRESENT,
    D3D12_RESOURCE_STATE_RENDER_TARGET, ID3D12CommandList,
};
use windows::Win32::Graphics::Dxgi::{DXGI_PRESENT, DXGI_PRESENT_PARAMETERS};
use windows::core::{Interface, Result};

/// C++: `DirectX::Colors::LightSteelBlue`.
const LIGHT_STEEL_BLUE: [f32; 4] = [0.690196097, 0.768627524, 0.870588303, 1.0];

struct InitDirect3DApp {
    base: D3DApp,
}

impl D3DAppHandler for InitDirect3DApp {
    fn base(&mut self) -> &mut D3DApp {
        &mut self.base
    }

    /// C++: `InitDirect3DApp::Update` — empty in this demo.
    fn update(&mut self) {}

    /// C++: `InitDirect3DApp::Draw`.
    fn draw(&mut self) -> Result<()> {
        let base = &mut self.base;

        // Reuse the memory associated with command recording. We can only reset when the
        // associated command lists have finished execution on the GPU (this demo flushes
        // per frame below, so that's guaranteed here).
        // SAFETY: allocator idle (queue flushed at the end of the previous frame).
        unsafe { base.direct_cmd_list_alloc.Reset() }?;

        // A command list can be reset after it has been added to the command queue via
        // ExecuteCommandList. Reusing the command list reuses memory.
        // SAFETY: list was closed at the end of the previous frame (or by OnResize).
        unsafe { base.command_list.Reset(&base.direct_cmd_list_alloc, None) }?;

        // (C++ sets the CbvSrvUav descriptor heap here for ImGui — next step.)

        // SAFETY: recording onto the open list; viewport/scissor set every reset.
        unsafe {
            base.command_list.RSSetViewports(&[base.screen_viewport]);
            base.command_list.RSSetScissorRects(&[base.scissor_rect]);
        }

        // Indicate a state transition on the resource usage.
        // SAFETY: back buffer is live; recording is open.
        unsafe {
            base.command_list.ResourceBarrier(&[transition_barrier(
                base.current_back_buffer(),
                D3D12_RESOURCE_STATE_PRESENT,
                D3D12_RESOURCE_STATE_RENDER_TARGET,
            )]);
        }

        // Clear the back buffer and depth buffer.
        // SAFETY: the views were created by OnResize for the live buffers.
        unsafe {
            base.command_list.ClearRenderTargetView(
                base.current_back_buffer_view(),
                &LIGHT_STEEL_BLUE,
                None,
            );
            base.command_list.ClearDepthStencilView(
                base.depth_stencil_view(),
                D3D12_CLEAR_FLAG_DEPTH | D3D12_CLEAR_FLAG_STENCIL,
                1.0,
                0,
                None,
            );

            // Specify the buffers we are going to render to.
            base.command_list.OMSetRenderTargets(
                1,
                Some(&base.current_back_buffer_view()),
                true,
                Some(&base.depth_stencil_view()),
            );
        }

        // (C++ renders the ImGui draw data here — next step.)

        // Indicate a state transition on the resource usage.
        // SAFETY: same back buffer, back to PRESENT.
        unsafe {
            base.command_list.ResourceBarrier(&[transition_barrier(
                base.current_back_buffer(),
                D3D12_RESOURCE_STATE_RENDER_TARGET,
                D3D12_RESOURCE_STATE_PRESENT,
            )]);
        }

        // Done recording commands.
        // SAFETY: list has valid commands; queue executes an array of one.
        unsafe {
            base.command_list.Close()?;
            let cmd_lists = [Some(base.command_list.cast::<ID3D12CommandList>()?)];
            base.command_queue.ExecuteCommandLists(&cmd_lists);
        }

        // Swap the back and front buffers.
        let present_params = DXGI_PRESENT_PARAMETERS::default();
        // SAFETY: standard present; params zeroed like the C++.
        unsafe { base.swap_chain.Present1(0, DXGI_PRESENT(0), &present_params) }.ok()?;
        base.curr_back_buffer = (base.curr_back_buffer + 1) % SWAP_CHAIN_BUFFER_COUNT;

        // Wait until frame commands are complete. This waiting is inefficient and is done
        // for simplicity. Later (ch 7, FrameResources) we organize the rendering code so we
        // do not have to wait per frame.
        base.flush_command_queue()
    }
}

fn main() -> std::process::ExitCode {
    match app_main() {
        Ok(code) => std::process::ExitCode::from(code as u8),
        Err(e) => {
            report_error(&e); // stderr log + message box (port convention)
            std::process::ExitCode::FAILURE
        }
    }
}

fn app_main() -> Result<i32> {
    let mut app = InitDirect3DApp {
        base: D3DApp::new("d3d App")?,
    };
    run(&mut app)
}
