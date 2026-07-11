//! Port of `Common/d3dApp.h/.cpp` (Frank Luna) — the framework every D3D demo shares.
//!
//! # Shape of the port
//!
//! The C++ is a virtual base class; the Rust split is:
//!
//! - [`D3DApp`] (struct) — all the base-class state, plus the non-virtual methods
//!   (`FlushCommandQueue`, `OnResize`'s body, frame stats, init).
//! - [`D3DAppHandler`] (trait) — the virtuals. `update`/`draw` are required (pure virtual in
//!   the book); `msg_proc`, `on_resize`, and the mouse hooks have default bodies that match
//!   the base-class implementations, overridable per demo exactly like the C++.
//! - [`run`] (free fn) — `D3DApp::Run()`, the PeekMessage game loop. It also owns the
//!   WndProc→app plumbing (below).
//!
//! # The WndProc plumbing (replaces the C++ `GetApp()` singleton)
//!
//! The C++ routes messages through a global `D3DApp* mApp`. Here, [`run`] stores a pointer
//! to the handler in the window's `GWLP_USERDATA` slot and the `wnd_proc` recovers it.
//! `&mut dyn D3DAppHandler` is a fat pointer (two words) and `USERDATA` holds one, so what
//! is stored is a pointer *to the fat pointer*, which lives on `run`'s stack for the whole
//! loop. Messages that arrive before `run` (during `CreateWindow`) see a null slot and fall
//! through to `DefWindowProc`, mirroring the C++ comment about `WM_CREATE` arriving before
//! `mhMainWnd` is assigned.
//!
//! # Deviations from the C++ (deliberate, all covered in the porting guide)
//!
//! - ImGui init/shutdown/new-frame: not yet ported (the ch 4 part-2 step).
//! - `GraphicsMemory`/`ResourceUploadBatch` (DirectXTK12): created at init in the C++ but
//!   first *used* in ch 6–7 — the port adds its upload arena there.
//! - `SamplerHeap`, `CbvSrvUavHeap`: first bound by demos with shaders; also deferred.
//! - Debug output goes to **stderr** (`eprintln!`), not `OutputDebugString` — including the
//!   debug layer itself, via `ID3D12InfoQueue1::RegisterMessageCallback` (the guide's
//!   "validation to stderr" side quest). Run from a terminal and you see everything.
//! - The Agility SDK exports are omitted: Windows 11's inbox runtime already provides
//!   SM 6.6 (verified against the C++ demos, which resolve to the system `D3D12Core.dll`).

use crate::descriptor_util::DescriptorHeap;
use crate::game_timer::GameTimer;
use windows::Win32::Foundation::{
    HINSTANCE, HWND, LPARAM, LRESULT, RECT, WAIT_OBJECT_0, WPARAM,
};
use windows::Win32::Graphics::Direct3D::D3D_FEATURE_LEVEL_12_2;
use windows::Win32::Graphics::Direct3D12::{
    D3D12_CLEAR_VALUE, D3D12_CLEAR_VALUE_0, D3D12_COMMAND_LIST_TYPE_DIRECT,
    D3D12_COMMAND_QUEUE_DESC, D3D12_CPU_DESCRIPTOR_HANDLE, D3D12_DEPTH_STENCIL_VALUE,
    D3D12_DESCRIPTOR_HEAP_TYPE_DSV, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, D3D12_FENCE_FLAG_NONE,
    D3D12_HEAP_FLAG_NONE, D3D12_HEAP_PROPERTIES, D3D12_HEAP_TYPE_DEFAULT,
    D3D12_MESSAGE_CALLBACK_FLAG_NONE, D3D12_MESSAGE_CATEGORY, D3D12_MESSAGE_ID,
    D3D12_MESSAGE_SEVERITY, D3D12_MESSAGE_SEVERITY_CORRUPTION, D3D12_MESSAGE_SEVERITY_ERROR,
    D3D12_MESSAGE_SEVERITY_INFO, D3D12_MESSAGE_SEVERITY_MESSAGE,
    D3D12_MESSAGE_SEVERITY_WARNING, D3D12_RESOURCE_DESC, D3D12_RESOURCE_DIMENSION_TEXTURE2D,
    D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL, D3D12_RESOURCE_STATE_COMMON,
    D3D12_RESOURCE_STATE_DEPTH_WRITE, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_VIEWPORT,
    D3D12CreateDevice, D3D12GetDebugInterface, ID3D12CommandAllocator, ID3D12CommandList,
    ID3D12CommandQueue, ID3D12Debug1, ID3D12Device5, ID3D12Fence, ID3D12GraphicsCommandList6,
    ID3D12InfoQueue1, ID3D12Resource,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT, DXGI_FORMAT_D24_UNORM_S8_UINT, DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory2, DXGI_CREATE_FACTORY_DEBUG, DXGI_CREATE_FACTORY_FLAGS,
    DXGI_ERROR_NOT_FOUND, DXGI_SCALING_NONE, DXGI_SWAP_CHAIN_DESC1,
    DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH, DXGI_SWAP_EFFECT_FLIP_DISCARD,
    DXGI_USAGE_RENDER_TARGET_OUTPUT, IDXGIAdapter, IDXGIAdapter4, IDXGIFactory6,
    IDXGISwapChain4,
};
use windows::Win32::Graphics::Gdi::{GetStockObject, HBRUSH, NULL_BRUSH, UpdateWindow};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{CreateEventW, INFINITE, WaitForSingleObject};
use windows::Win32::UI::Input::KeyboardAndMouse::VK_ESCAPE;
use windows::Win32::UI::WindowsAndMessaging::{
    AdjustWindowRect, CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, CreateWindowExW, DefWindowProcW,
    DispatchMessageW, GWLP_USERDATA, GetWindowLongPtrW, IDC_ARROW, IDI_APPLICATION,
    LoadCursorW, LoadIconW, MINMAXINFO, MSG, PM_REMOVE, PeekMessageW, PostQuitMessage,
    RegisterClassW, SW_SHOW, SetWindowLongPtrW, SetWindowTextW, ShowWindow, TranslateMessage,
    WINDOW_EX_STYLE, WM_ACTIVATE, WM_DESTROY, WM_ENTERSIZEMOVE, WM_EXITSIZEMOVE,
    WM_GETMINMAXINFO, WM_KEYUP, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP,
    WM_MENUCHAR, WM_MOUSEMOVE, WM_QUIT, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SIZE, WNDCLASSW,
    WS_OVERLAPPEDWINDOW,
};
use windows::core::{BOOL, HSTRING, Interface, PCSTR, Result, w};

pub const SWAP_CHAIN_BUFFER_COUNT: usize = 2;

pub struct D3DApp {
    pub hwnd: HWND,
    pub instance: HINSTANCE,

    pub app_paused: bool, // is the application paused?
    pub minimized: bool,  // is the application minimized?
    pub maximized: bool,  // is the application maximized?
    pub resizing: bool,   // are the resize bars being dragged?

    pub timer: GameTimer,

    // Resources and views (declared before the device/queue: Rust drops fields in
    // declaration order, and children should go before their device — the queue flush
    // itself happens in Drop below).
    pub curr_back_buffer: usize,
    pub swap_chain_buffer: [Option<ID3D12Resource>; SWAP_CHAIN_BUFFER_COUNT],
    pub depth_stencil_buffer: Option<ID3D12Resource>,
    pub rtv_heap: DescriptorHeap,
    pub dsv_heap: DescriptorHeap,

    pub fence: ID3D12Fence,
    pub current_fence: u64,

    pub direct_cmd_list_alloc: ID3D12CommandAllocator,
    pub command_list: ID3D12GraphicsCommandList6,
    pub command_queue: ID3D12CommandQueue,

    pub swap_chain: IDXGISwapChain4,
    pub default_adapter: IDXGIAdapter4,
    pub device: ID3D12Device5,
    pub dxgi_factory: IDXGIFactory6,

    pub screen_viewport: D3D12_VIEWPORT,
    pub scissor_rect: RECT,

    pub main_wnd_caption: String,
    pub back_buffer_format: DXGI_FORMAT,
    pub depth_stencil_format: DXGI_FORMAT,
    pub client_width: i32,
    pub client_height: i32,

    // CalculateFrameStats' function-local statics in the C++.
    frame_cnt: i32,
    time_elapsed: f32,
}

/// The book's virtual interface. `update`/`draw` are the pure virtuals; everything else has
/// a default body identical to the C++ base class, overridable per demo.
pub trait D3DAppHandler {
    fn base(&mut self) -> &mut D3DApp;

    /// C++: `virtual void Update(const GameTimer&) = 0;`
    fn update(&mut self);
    /// C++: `virtual void Draw(const GameTimer&) = 0;`
    fn draw(&mut self) -> Result<()>;

    /// C++: `virtual void OnResize();` — the base body lives on [`D3DApp`] so overrides can
    /// still call it (`self.base().on_resize_base()`), like `D3DApp::OnResize()` in C++.
    fn on_resize(&mut self) {
        self.base()
            .on_resize_base()
            .expect("OnResize failed (ResizeBuffers/depth-buffer recreation)");
    }

    // Convenience overrides for handling mouse input.
    fn on_mouse_down(&mut self, _btn_state: WPARAM, _x: i32, _y: i32) {}
    fn on_mouse_up(&mut self, _btn_state: WPARAM, _x: i32, _y: i32) {}
    fn on_mouse_move(&mut self, _btn_state: WPARAM, _x: i32, _y: i32) {}

    /// C++: `virtual LRESULT MsgProc(...)` — default body is the book's, verbatim.
    fn msg_proc(&mut self, hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        // WindowsX.h's GET_X_LPARAM / GET_Y_LPARAM (signed 16-bit halves).
        let x = |l: LPARAM| (l.0 & 0xffff) as u16 as i16 as i32;
        let y = |l: LPARAM| ((l.0 >> 16) & 0xffff) as u16 as i16 as i32;

        match msg {
            // WM_ACTIVATE is sent when the window is activated or deactivated. We pause
            // the game when the window is deactivated and unpause it when it becomes active.
            WM_ACTIVATE => {
                const WA_INACTIVE: usize = 0;
                let base = self.base();
                if (wparam.0 & 0xffff) == WA_INACTIVE {
                    base.app_paused = true;
                    base.timer.stop();
                } else {
                    base.app_paused = false;
                    base.timer.start();
                }
                LRESULT(0)
            }

            // WM_SIZE is sent when the user resizes the window.
            WM_SIZE => {
                const SIZE_MINIMIZED: usize = 1;
                const SIZE_MAXIMIZED: usize = 2;
                const SIZE_RESTORED: usize = 0;

                // Save the new client area dimensions.
                let base = self.base();
                base.client_width = x(lparam);
                base.client_height = y(lparam);
                match wparam.0 {
                    SIZE_MINIMIZED => {
                        base.app_paused = true;
                        base.minimized = true;
                        base.maximized = false;
                    }
                    SIZE_MAXIMIZED => {
                        base.app_paused = false;
                        base.minimized = false;
                        base.maximized = true;
                        self.on_resize();
                    }
                    SIZE_RESTORED => {
                        if base.minimized {
                            // Restoring from minimized state?
                            base.app_paused = false;
                            base.minimized = false;
                            self.on_resize();
                        } else if base.maximized {
                            // Restoring from maximized state?
                            base.app_paused = false;
                            base.maximized = false;
                            self.on_resize();
                        } else if base.resizing {
                            // While the user drags the resize bars a stream of WM_SIZE
                            // messages arrives; resizing buffers per message would be
                            // pointless and slow. Wait for WM_EXITSIZEMOVE instead.
                        } else {
                            // API call such as SetWindowPos or SetFullscreenState.
                            self.on_resize();
                        }
                    }
                    _ => {}
                }
                LRESULT(0)
            }

            // WM_ENTERSIZEMOVE is sent when the user grabs the resize bars.
            WM_ENTERSIZEMOVE => {
                let base = self.base();
                base.app_paused = true;
                base.resizing = true;
                base.timer.stop();
                LRESULT(0)
            }

            // WM_EXITSIZEMOVE is sent when the user releases the resize bars.
            // Here we reset everything based on the new window dimensions.
            WM_EXITSIZEMOVE => {
                let base = self.base();
                base.app_paused = false;
                base.resizing = false;
                base.timer.start();
                self.on_resize();
                LRESULT(0)
            }

            // WM_DESTROY is sent when the window is being destroyed.
            WM_DESTROY => {
                // SAFETY: FFI with no preconditions.
                unsafe { PostQuitMessage(0) };
                LRESULT(0)
            }

            // Don't beep when we alt-enter (menu-less window). MAKELRESULT(0, MNC_CLOSE).
            WM_MENUCHAR => LRESULT(0x0001_0000),

            // Catch this message so as to prevent the window from becoming too small.
            WM_GETMINMAXINFO => {
                // SAFETY: for WM_GETMINMAXINFO the OS guarantees lparam points at a
                // writable MINMAXINFO for the duration of the message.
                unsafe {
                    let info = lparam.0 as *mut MINMAXINFO;
                    (*info).ptMinTrackSize.x = 200;
                    (*info).ptMinTrackSize.y = 200;
                }
                LRESULT(0)
            }

            WM_LBUTTONDOWN | WM_MBUTTONDOWN | WM_RBUTTONDOWN => {
                self.on_mouse_down(wparam, x(lparam), y(lparam));
                LRESULT(0)
            }
            WM_LBUTTONUP | WM_MBUTTONUP | WM_RBUTTONUP => {
                self.on_mouse_up(wparam, x(lparam), y(lparam));
                LRESULT(0)
            }
            WM_MOUSEMOVE => {
                self.on_mouse_move(wparam, x(lparam), y(lparam));
                LRESULT(0)
            }
            WM_KEYUP => {
                if wparam.0 == VK_ESCAPE.0 as usize {
                    // SAFETY: FFI with no preconditions.
                    unsafe { PostQuitMessage(0) };
                }
                LRESULT(0)
            }

            // SAFETY: forwarding the exact arguments this callback received.
            _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
        }
    }
}

impl D3DApp {
    /// C++: the `D3DApp(hInstance)` constructor + `Initialize()` (window, then Direct3D),
    /// fused — Rust has no half-initialized objects, so everything is built here and the
    /// initial `OnResize` is the caller's first act via the handler (see [`run`]).
    pub fn new(caption: &str) -> Result<Self> {
        // SAFETY: FFI with no preconditions; None = current executable's module.
        let instance: HINSTANCE = unsafe { GetModuleHandleW(None) }?.into();

        let client_width = 1280;
        let client_height = 720;

        let hwnd = init_main_window(instance, caption, client_width, client_height)?;

        // ---- InitDirect3D ----
        let mut factory_flags = DXGI_CREATE_FACTORY_FLAGS(0);
        if cfg!(debug_assertions) {
            factory_flags = DXGI_CREATE_FACTORY_DEBUG;

            // Enable the D3D12 debug layer.
            let mut debug0: Option<windows::Win32::Graphics::Direct3D12::ID3D12Debug> = None;
            // SAFETY: standard out-param call; debug0 receives an owned interface.
            unsafe { D3D12GetDebugInterface(&mut debug0) }?;
            let debug1: ID3D12Debug1 = debug0
                .expect("D3D12GetDebugInterface returned S_OK with no interface")
                .cast()?; // C++: debugController0.As(&debugController1)
            // SAFETY: FFI with no preconditions.
            unsafe { debug1.EnableDebugLayer() };
            // debug1.SetEnableGPUBasedValidation(true) — like the book, off by default.
        }

        // SAFETY: standard factory creation.
        let dxgi_factory: IDXGIFactory6 = unsafe { CreateDXGIFactory2(factory_flags) }?;

        // Find an adapter that supports D3D_FEATURE_LEVEL_12_2. This is mainly for laptops,
        // so it picks the discrete GPU over the integrated GPU.
        let mut found: Option<(IDXGIAdapter, ID3D12Device5)> = None;
        for i in 0.. {
            // SAFETY: enumeration; each Ok result is an owned adapter reference.
            let adapter: IDXGIAdapter = match unsafe { dxgi_factory.EnumAdapters(i) } {
                Ok(a) => a,
                Err(e) if e.code() == DXGI_ERROR_NOT_FOUND => break,
                Err(e) => return Err(e),
            };
            // Try to create hardware device.
            let mut device: Option<windows::Win32::Graphics::Direct3D12::ID3D12Device> = None;
            // SAFETY: standard out-param call.
            if unsafe { D3D12CreateDevice(&adapter, D3D_FEATURE_LEVEL_12_2, &mut device) }
                .is_ok()
            {
                let device5: ID3D12Device5 =
                    device.expect("D3D12CreateDevice succeeded with no device").cast()?;
                found = Some((adapter, device5));
                break;
            }
            // Adapters we don't keep drop (Release) here.
        }
        let Some((adapter, device)) = found else {
            // C++: MessageBox "Could not find D3D_FEATURE_LEVEL_12_2 GPU" — our caller's
            // report_error shows the message box.
            return Err(windows::core::Error::new(
                windows::Win32::Foundation::E_FAIL,
                "Could not find D3D_FEATURE_LEVEL_12_2 GPU",
            ));
        };

        // Get default adapter, so we can IDXGIAdapter3::QueryVideoMemoryInfo (used by demos).
        let default_adapter: IDXGIAdapter4 = adapter.cast()?; // C++: foundAdapter.As(...)

        // SAFETY: standard creation call.
        let fence: ID3D12Fence = unsafe { device.CreateFence(0, D3D12_FENCE_FLAG_NONE) }?;

        if cfg!(debug_assertions) {
            log_adapters(&dxgi_factory);
            register_debug_callback(&device);
        }

        // ---- CreateCommandObjects ----
        let queue_desc = D3D12_COMMAND_QUEUE_DESC {
            Type: D3D12_COMMAND_LIST_TYPE_DIRECT,
            ..Default::default()
        };
        // SAFETY: desc fully initialized; standard creation calls throughout.
        let command_queue: ID3D12CommandQueue =
            unsafe { device.CreateCommandQueue(&queue_desc) }?;
        let direct_cmd_list_alloc: ID3D12CommandAllocator =
            unsafe { device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT) }?;
        let command_list: ID3D12GraphicsCommandList6 = unsafe {
            device.CreateCommandList(
                0,
                D3D12_COMMAND_LIST_TYPE_DIRECT,
                &direct_cmd_list_alloc, // Associated command allocator
                None,                   // Initial PipelineStateObject
            )
        }?;
        // Start off in a closed state. The first time we refer to the command list we
        // Reset it, and it needs to be closed before calling Reset.
        // SAFETY: list was just created open, with no commands recorded.
        unsafe { command_list.Close() }?;

        // ---- CreateSwapChain ----
        let back_buffer_format = DXGI_FORMAT_R8G8B8A8_UNORM;
        let sd = DXGI_SWAP_CHAIN_DESC1 {
            Width: client_width as u32,
            Height: client_height as u32,
            Format: back_buffer_format,
            Stereo: BOOL(0),
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount: SWAP_CHAIN_BUFFER_COUNT as u32,
            Scaling: DXGI_SCALING_NONE,
            SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
            AlphaMode: windows::Win32::Graphics::Dxgi::Common::DXGI_ALPHA_MODE_UNSPECIFIED,
            Flags: DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH.0 as u32,
        };
        // Note: swap chain uses queue to perform flush.
        // SAFETY: hwnd is our live window; desc fully initialized.
        let swap_chain1 = unsafe {
            dxgi_factory.CreateSwapChainForHwnd(&command_queue, hwnd, &sd, None, None)
        }?;
        let swap_chain: IDXGISwapChain4 = swap_chain1.cast()?; // C++: swapChain1.As(...)

        // ---- CreateRtvAndDsvDescriptorHeaps ----
        let rtv_heap = DescriptorHeap::new(
            &device,
            D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
            SWAP_CHAIN_BUFFER_COUNT as u32,
        )?;
        let dsv_heap = DescriptorHeap::new(&device, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1)?;

        // (Deferred vs the C++: SamplerHeap, GraphicsMemory, ResourceUploadBatch — see the
        // module docs. They arrive with the chapters that first use them.)

        Ok(Self {
            hwnd,
            instance,
            app_paused: false,
            minimized: false,
            maximized: false,
            resizing: false,
            timer: GameTimer::new(),
            curr_back_buffer: 0,
            swap_chain_buffer: [None, None],
            depth_stencil_buffer: None,
            rtv_heap,
            dsv_heap,
            fence,
            current_fence: 0,
            direct_cmd_list_alloc,
            command_list,
            command_queue,
            swap_chain,
            default_adapter,
            device,
            dxgi_factory,
            screen_viewport: D3D12_VIEWPORT::default(),
            scissor_rect: RECT::default(),
            main_wnd_caption: caption.to_string(),
            back_buffer_format,
            depth_stencil_format: DXGI_FORMAT_D24_UNORM_S8_UINT,
            client_width,
            client_height,
            frame_cnt: 0,
            time_elapsed: 0.0,
        })
    }

    pub fn aspect_ratio(&self) -> f32 {
        self.client_width as f32 / self.client_height as f32
    }

    /// C++: `FlushCommandQueue()` — half the book's correctness hangs off this.
    pub fn flush_command_queue(&mut self) -> Result<()> {
        // Advance the fence value to mark commands up to this fence point.
        self.current_fence += 1;

        // Because we are on the GPU timeline, the new fence point won't be set until the
        // GPU finishes processing all the commands prior to this Signal().
        // SAFETY: fence and queue are live; standard signal call.
        unsafe { self.command_queue.Signal(&self.fence, self.current_fence) }?;

        // Wait until the GPU has completed commands up to this fence point.
        // SAFETY: GetCompletedValue has no preconditions.
        if unsafe { self.fence.GetCompletedValue() } < self.current_fence {
            // SAFETY: creating an unnamed manual-reset-less event; owned handle returned.
            let event =
                unsafe { CreateEventW(None, false, false, windows::core::PCWSTR::null()) }?;
            // Fire event when GPU hits current fence.
            // SAFETY: event is a valid handle we own.
            unsafe { self.fence.SetEventOnCompletion(self.current_fence, event) }?;
            // SAFETY: blocking wait on our own event; INFINITE per the book.
            let wait = unsafe { WaitForSingleObject(event, INFINITE) };
            debug_assert_eq!(wait, WAIT_OBJECT_0);
            // SAFETY: closing the handle we created above.
            unsafe { windows::Win32::Foundation::CloseHandle(event) }?;
        }
        Ok(())
    }

    /// C++: `D3DApp::OnResize()` — the base body. THE ComPtr trap of the book lives here:
    /// every back-buffer reference must be dropped before `ResizeBuffers`, or it fails with
    /// `E_INVALIDARG` ("buffer still referenced"). In Rust that's assigning `None`.
    pub fn on_resize_base(&mut self) -> Result<()> {
        // Flush before changing any resources.
        self.flush_command_queue()?;

        // SAFETY: allocator/list are idle (queue just flushed); list was closed.
        unsafe { self.command_list.Reset(&self.direct_cmd_list_alloc, None) }?;

        // Release the previous resources we will be recreating.
        for buffer in &mut self.swap_chain_buffer {
            *buffer = None; // C++: mSwapChainBuffer[i].Reset();
        }
        self.depth_stencil_buffer = None;

        // Resize the swap chain.
        // SAFETY: zero outstanding back-buffer references (just dropped above).
        unsafe {
            self.swap_chain.ResizeBuffers(
                SWAP_CHAIN_BUFFER_COUNT as u32,
                self.client_width as u32,
                self.client_height as u32,
                self.back_buffer_format,
                DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH,
            )
        }?;

        self.curr_back_buffer = 0;

        for i in 0..SWAP_CHAIN_BUFFER_COUNT {
            // SAFETY: i < buffer count; GetBuffer hands back an owned reference (we own the
            // new back buffers again, per the book).
            let buffer: ID3D12Resource = unsafe { self.swap_chain.GetBuffer(i as u32) }?;
            // SAFETY: buffer is live; None view desc = default for the resource format.
            unsafe {
                self.device.CreateRenderTargetView(
                    &buffer,
                    None,
                    self.rtv_heap.cpu_handle(i as u32),
                )
            };
            self.swap_chain_buffer[i] = Some(buffer);
        }

        // Create the depth/stencil buffer and view.
        let depth_stencil_desc = D3D12_RESOURCE_DESC {
            Dimension: D3D12_RESOURCE_DIMENSION_TEXTURE2D,
            Alignment: 0,
            Width: self.client_width as u64,
            Height: self.client_height as u32,
            DepthOrArraySize: 1,
            MipLevels: 1,
            Format: self.depth_stencil_format,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Layout: D3D12_TEXTURE_LAYOUT_UNKNOWN,
            Flags: D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL,
        };
        let heap_properties = D3D12_HEAP_PROPERTIES {
            Type: D3D12_HEAP_TYPE_DEFAULT,
            ..Default::default()
        };
        let opt_clear = D3D12_CLEAR_VALUE {
            Format: self.depth_stencil_format,
            Anonymous: D3D12_CLEAR_VALUE_0 {
                DepthStencil: D3D12_DEPTH_STENCIL_VALUE { Depth: 1.0, Stencil: 0 },
            },
        };
        let mut depth_buffer: Option<ID3D12Resource> = None;
        // SAFETY: descs fully initialized; out-param receives an owned resource.
        unsafe {
            self.device.CreateCommittedResource(
                &heap_properties,
                D3D12_HEAP_FLAG_NONE,
                &depth_stencil_desc,
                D3D12_RESOURCE_STATE_COMMON,
                Some(&opt_clear),
                &mut depth_buffer,
            )
        }?;
        let depth_buffer = depth_buffer.expect("CreateCommittedResource returned no resource");

        // Create descriptor to mip level 0 of entire resource using the resource's format.
        // SAFETY: depth buffer is live; None = default view desc.
        unsafe {
            self.device
                .CreateDepthStencilView(&depth_buffer, None, self.depth_stencil_view())
        };

        // Transition the resource from its initial state to be used as a depth buffer.
        let barrier = crate::d3d_util::transition_barrier(
            &depth_buffer,
            D3D12_RESOURCE_STATE_COMMON,
            D3D12_RESOURCE_STATE_DEPTH_WRITE,
        );
        // SAFETY: recording onto an open list; barrier resource is live.
        unsafe { self.command_list.ResourceBarrier(&[barrier]) };
        self.depth_stencil_buffer = Some(depth_buffer);

        // Execute the resize commands.
        // SAFETY: list has valid commands recorded; queue executes an array of one.
        unsafe {
            self.command_list.Close()?;
            let cmd_lists = [Some(self.command_list.cast::<ID3D12CommandList>()?)];
            self.command_queue.ExecuteCommandLists(&cmd_lists);
        }

        // Wait until resize is complete.
        self.flush_command_queue()?;

        // Update the viewport transform to cover the client area.
        self.screen_viewport = D3D12_VIEWPORT {
            TopLeftX: 0.0,
            TopLeftY: 0.0,
            Width: self.client_width as f32,
            Height: self.client_height as f32,
            MinDepth: 0.0,
            MaxDepth: 1.0,
        };
        self.scissor_rect = RECT {
            left: 0,
            top: 0,
            right: self.client_width,
            bottom: self.client_height,
        };
        Ok(())
    }

    /// C++: `CurrentBackBuffer()`.
    pub fn current_back_buffer(&self) -> &ID3D12Resource {
        self.swap_chain_buffer[self.curr_back_buffer]
            .as_ref()
            .expect("back buffers exist between OnResize calls")
    }

    /// C++: `CurrentBackBufferView()`.
    pub fn current_back_buffer_view(&self) -> D3D12_CPU_DESCRIPTOR_HANDLE {
        self.rtv_heap.cpu_handle(self.curr_back_buffer as u32)
    }

    /// C++: `DepthStencilView()`.
    pub fn depth_stencil_view(&self) -> D3D12_CPU_DESCRIPTOR_HANDLE {
        self.dsv_heap.cpu_handle(0)
    }

    /// C++: `CalculateFrameStats()` — average FPS/mspf appended to the window caption.
    fn calculate_frame_stats(&mut self) {
        self.frame_cnt += 1;

        // Compute averages over one second period.
        if self.timer.total_time() - self.time_elapsed >= 1.0 {
            let fps = self.frame_cnt as f32; // fps = frame_cnt / 1
            let mspf = 1000.0 / fps;

            // {:.6} matches C++ std::to_wstring(float)'s formatting.
            let window_text =
                format!("{}    fps: {fps:.6}   mspf: {mspf:.6}", self.main_wnd_caption);
            // SAFETY: hwnd is our live window.
            let _ = unsafe { SetWindowTextW(self.hwnd, &HSTRING::from(window_text)) };

            // Reset for next average.
            self.frame_cnt = 0;
            self.time_elapsed += 1.0;
        }
    }
}

impl Drop for D3DApp {
    /// C++: `~D3DApp()` — wait for the GPU before the interfaces start dropping.
    fn drop(&mut self) {
        let _ = self.flush_command_queue();
    }
}

/// C++: `D3DApp::Run()` + the `MainWndProc`→app plumbing (see module docs).
pub fn run(handler: &mut dyn D3DAppHandler) -> Result<i32> {
    // Do the initial resize code (the tail of the C++ Initialize()).
    handler.on_resize();

    let hwnd = handler.base().hwnd;

    // Store a pointer to the fat `&mut dyn` pointer in the window's user-data slot.
    let mut handler_ptr: &mut dyn D3DAppHandler = handler;
    // SAFETY: handler_ptr outlives the message loop below; the slot is cleared before it
    // goes out of scope. wnd_proc only dereferences it on this (the window's) thread, and
    // the loop does not touch the handler while DispatchMessageW may be inside it.
    unsafe {
        SetWindowLongPtrW(
            hwnd,
            GWLP_USERDATA,
            &mut handler_ptr as *mut &mut dyn D3DAppHandler as isize,
        )
    };

    let mut msg = MSG::default();
    handler_ptr.base().timer.reset();

    while msg.message != WM_QUIT {
        // If there are Window messages then process them.
        // SAFETY: msg is a valid MSG; standard PeekMessage pump.
        if unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {
            // SAFETY: msg was just filled by PeekMessageW.
            unsafe {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        } else {
            // Otherwise, do animation/game stuff.
            handler_ptr.base().timer.tick();

            if !handler_ptr.base().app_paused {
                handler_ptr.base().calculate_frame_stats();
                handler_ptr.update();
                handler_ptr.draw()?;
            } else {
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    }

    // SAFETY: clearing the slot before handler_ptr leaves scope.
    unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0) };

    Ok(msg.wParam.0 as i32)
}

/// The registered window procedure: recover the handler from GWLP_USERDATA and forward to
/// its `msg_proc` (the C++ forwards through the `GetApp()` singleton instead).
extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    // SAFETY: the slot is either null (messages before/after `run`, e.g. WM_CREATE) or the
    // pointer `run` stored, whose referent is alive for the duration of the loop; only this
    // thread dispatches messages, so no aliasing &mut is live while we use it.
    unsafe {
        let slot = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut &mut dyn D3DAppHandler;
        if slot.is_null() {
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        }
        (*slot).msg_proc(hwnd, msg, wparam, lparam)
    }
}

/// C++: `D3DApp::InitMainWindow()`.
fn init_main_window(
    instance: HINSTANCE,
    caption: &str,
    client_width: i32,
    client_height: i32,
) -> Result<HWND> {
    let wc = WNDCLASSW {
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(wnd_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        // SAFETY: FFI; shared stock icon/cursor/brush, never freed by us.
        hIcon: unsafe { LoadIconW(None, IDI_APPLICATION) }?,
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW) }?,
        hbrBackground: HBRUSH(unsafe { GetStockObject(NULL_BRUSH) }.0),
        lpszMenuName: w!(""),
        lpszClassName: w!("MainWnd"),
    };
    // SAFETY: wc fully initialized; class name is a static wide literal.
    if unsafe { RegisterClassW(&wc) } == 0 {
        return Err(windows::core::Error::from_thread());
    }

    // Compute window rectangle dimensions based on requested client area dimensions.
    let mut r = RECT {
        left: 0,
        top: 0,
        right: client_width,
        bottom: client_height,
    };
    // SAFETY: r is a valid RECT.
    unsafe { AdjustWindowRect(&mut r, WS_OVERLAPPEDWINDOW, false) }?;
    let width = r.right - r.left;
    let height = r.bottom - r.top;

    // SAFETY: class registered above; no parent/menu/creation param.
    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("MainWnd"),
            &HSTRING::from(caption),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            width,
            height,
            None,
            None,
            Some(instance),
            None,
        )
    }?;

    // SAFETY: hwnd is the live window created above.
    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = UpdateWindow(hwnd);
    }
    Ok(hwnd)
}

/// The guide's "validation to stderr" side quest: route debug-layer messages through
/// `ID3D12InfoQueue1::RegisterMessageCallback` so lightweight editors/terminals see them
/// (the debug layer's default channel is OutputDebugString, which only debuggers hear).
fn register_debug_callback(device: &ID3D12Device5) {
    extern "system" fn debug_callback(
        _category: D3D12_MESSAGE_CATEGORY,
        severity: D3D12_MESSAGE_SEVERITY,
        id: D3D12_MESSAGE_ID,
        description: PCSTR,
        _context: *mut core::ffi::c_void,
    ) {
        let severity = match severity {
            D3D12_MESSAGE_SEVERITY_CORRUPTION => "CORRUPTION",
            D3D12_MESSAGE_SEVERITY_ERROR => "ERROR",
            D3D12_MESSAGE_SEVERITY_WARNING => "WARNING",
            D3D12_MESSAGE_SEVERITY_INFO => "INFO",
            D3D12_MESSAGE_SEVERITY_MESSAGE => "MESSAGE",
            _ => "?",
        };
        // SAFETY: the runtime guarantees description is a valid NUL-terminated string for
        // the duration of the callback.
        let text = unsafe { description.to_string() }.unwrap_or_default();
        eprintln!("[d3d12 {severity}] (id {}) {text}", id.0);
    }

    // The cast fails when the debug layer is off (release builds); that's fine.
    if let Ok(info_queue) = device.cast::<ID3D12InfoQueue1>() {
        let mut cookie = 0u32;
        // SAFETY: the callback is a plain fn with the required ABI and no captured state;
        // it stays registered (and valid) for the device's lifetime.
        let _ = unsafe {
            info_queue.RegisterMessageCallback(
                Some(debug_callback),
                D3D12_MESSAGE_CALLBACK_FLAG_NONE,
                std::ptr::null_mut(),
                &mut cookie,
            )
        };
    }
}

/// C++: `LogAdapters()`/`LogAdapterOutputs()` — to stderr instead of OutputDebugString.
/// (The book also logs every display mode; ported as a count to keep startup output short.)
fn log_adapters(factory: &IDXGIFactory6) {
    for i in 0.. {
        // SAFETY: enumeration; owned adapter reference per Ok result, dropped each loop.
        let adapter: IDXGIAdapter = match unsafe { factory.EnumAdapters(i) } {
            Ok(a) => a,
            Err(_) => break,
        };
        // SAFETY: desc out-param filled by the call.
        if let Ok(desc) = unsafe { adapter.GetDesc() } {
            let name = String::from_utf16_lossy(&desc.Description)
                .trim_end_matches('\0')
                .to_string();
            eprintln!("***Adapter: {name}");
        }
        for j in 0.. {
            // SAFETY: enumeration; owned output reference per Ok result.
            let output = match unsafe { adapter.EnumOutputs(j) } {
                Ok(o) => o,
                Err(_) => break,
            };
            // SAFETY: desc out-param filled by the call.
            if let Ok(desc) = unsafe { output.GetDesc() } {
                let name = String::from_utf16_lossy(&desc.DeviceName)
                    .trim_end_matches('\0')
                    .to_string();
                eprintln!("***Output: {name}");
            }
        }
    }
}
