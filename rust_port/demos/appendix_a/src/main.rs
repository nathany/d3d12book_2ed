//! Port of the book's Appendix A sample (`InitWindowsApp` — the "Hello, World" Win32
//! window). The 2nd edition's source ships no Appendix A demo, so this follows the program
//! printed in the appendix text, using the same conventions `Common/d3dApp.cpp` uses for the
//! real window in chapter 4 (plain `WNDCLASS`, default icon/cursor, `CreateWindow`).
//!
//! Behavior, per the book: a white window titled "Win32Basic"; left-click shows a
//! "Hello, World" message box; Escape destroys the window and the app exits cleanly.
//!
//! # Win32 → windows crate, the Appendix A differences
//!
//! - **`WinMain` → plain `main`.** No `nShowCmd` (we pass `SW_SHOW`), and we keep the
//!   console subsystem deliberately — from chapter 4 on, debug-layer messages go to stderr.
//! - **Wide APIs.** The `windows` crate binds the `W` variants; `w!("…")` builds a UTF-16
//!   `PCWSTR` literal at compile time (the C++ gets the same via `L"…"`).
//! - **The `WndProc` is a plain `extern "system"` function.** No state plumbing is needed
//!   here; note the book's global `ghMainWnd` disappears — the callback's own `hwnd`
//!   parameter is the same window, so `DestroyWindow(hwnd)` replaces it. (Chapter 4's
//!   `D3DApp` *does* need state in the WndProc; that's where the `GWLP_USERDATA` pattern
//!   comes in.)
//! - **Error handling:** fallible calls return `windows::core::Result` and `?` propagates
//!   everything to `main`, which logs the error to stderr **and** shows it in a message box
//!   — the book's `MessageBox(0, L"…FAILED", 0, 0)` style, done once at the top instead of
//!   at every call site. A windowed app can't count on anyone watching a console.
//! - The appendix uses the **blocking `GetMessage` loop** (ported below, including the
//!   book's `-1` error check); chapter 4 switches to `PeekMessage` for the game loop.

use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{GetStockObject, HBRUSH, UpdateWindow, WHITE_BRUSH};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::VK_ESCAPE;
use windows::Win32::UI::WindowsAndMessaging::{
    CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, CreateWindowExW, DefWindowProcW, DestroyWindow,
    DispatchMessageW, GetMessageW, IDC_ARROW, IDI_APPLICATION, LoadCursorW, LoadIconW,
    MB_ICONERROR, MB_OK, MSG, MessageBoxW, PostQuitMessage, RegisterClassW, SW_SHOW, ShowWindow,
    TranslateMessage, WINDOW_EX_STYLE, WM_DESTROY, WM_KEYDOWN, WM_LBUTTONDOWN,
    WNDCLASSW, WS_OVERLAPPEDWINDOW,
};
use windows::core::{HSTRING, Result, w};

/// C++: `int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE, PSTR, int nShowCmd)`
fn main() -> std::process::ExitCode {
    match app_main() {
        Ok(code) => code,
        Err(e) => {
            // Both channels on purpose: the log line for consoles/CI, the message box for
            // a human running the windowed app (the book's MessageBox-on-failure style).
            eprintln!("fatal error: {e}");
            report_error(&e);
            std::process::ExitCode::FAILURE
        }
    }
}

fn app_main() -> Result<std::process::ExitCode> {
    // SAFETY: FFI with no preconditions; None asks for the current executable's module.
    let instance: HINSTANCE = unsafe { GetModuleHandleW(None) }?.into();

    // C++: if(!InitWindowsApp(hInstance, nShowCmd)) return 0;
    init_windows_app(instance)?;

    // C++: return Run();
    run()
}

/// The book's error style (`MessageBox(0, L"…FAILED", 0, 0)`), centralized. `HSTRING`
/// converts a runtime Rust string to the UTF-16 the `W` API wants (`w!` only does literals).
fn report_error(e: &windows::core::Error) {
    let text = HSTRING::from(e.to_string());
    // SAFETY: FFI; None parent because the main window may not exist (yet, or anymore).
    unsafe { MessageBoxW(None, &text, w!("Error"), MB_OK | MB_ICONERROR) };
}

/// C++: `bool InitWindowsApp(HINSTANCE instanceHandle, int show)`
fn init_windows_app(instance: HINSTANCE) -> Result<HWND> {
    // The first task to creating a window is to describe some of its
    // characteristics by filling out a WNDCLASS structure.
    let wc = WNDCLASSW {
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(wnd_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: instance,
        // SAFETY: FFI; None + a system id loads a shared stock icon/cursor.
        hIcon: unsafe { LoadIconW(None, IDI_APPLICATION) }?,
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW) }?,
        // C++: (HBRUSH)GetStockObject(WHITE_BRUSH) — same cast, Rust spelling.
        // SAFETY: FFI with no preconditions; stock objects need not be freed.
        hbrBackground: HBRUSH(unsafe { GetStockObject(WHITE_BRUSH) }.0),
        lpszMenuName: w!(""),
        lpszClassName: w!("BasicWndClass"),
    };

    // Next, we register this WNDCLASS instance with Windows so that we can
    // create a window based on it. C++ shows a MessageBox on failure; we return an error.
    // SAFETY: wc is fully initialized and only read during the call; the class name is a
    // static wide-string literal, and wnd_proc has the required extern "system" ABI.
    if unsafe { RegisterClassW(&wc) } == 0 {
        return Err(windows::core::Error::from_thread()); // C++: MessageBox "RegisterClass FAILED"
    }

    // With our WNDCLASS instance registered, we can create a window with the
    // CreateWindow function.
    // SAFETY: the class was registered above under this instance; no parent, menu, or
    // creation parameter is passed.
    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            w!("BasicWndClass"),          // Registered WNDCLASS instance to use.
            w!("Win32Basic"),             // window title
            WS_OVERLAPPEDWINDOW,          // style flags
            CW_USEDEFAULT,                // x-coordinate
            CW_USEDEFAULT,                // y-coordinate
            CW_USEDEFAULT,                // width
            CW_USEDEFAULT,                // height
            None,                         // parent window
            None,                         // menu handle
            Some(instance),               // app instance
            None,                         // extra creation parameters
        )
    }?; // C++: MessageBox "CreateWindow FAILED" — the Result carries the failure instead

    // Even though we just created a window, it is not initially shown.
    // SAFETY: hwnd is the live window created above; return values are informational.
    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOW); // C++: ShowWindow(ghMainWnd, show);
        // UpdateWindow sends WM_PAINT straight to the WndProc (bypassing the queue) so the
        // first paint happens *now* instead of whenever the message loop gets to it —
        // classic GDI boilerplate for a snappy first frame. Nearly moot here (we don't
        // handle WM_PAINT; the class brush erases to white), and fully moot from ch 4 on,
        // where the game loop renders every frame without waiting for paint messages.
        let _ = UpdateWindow(hwnd);
    }

    Ok(hwnd)
}

/// C++: `int Run()` — the blocking GetMessage loop, including the book's -1 error check.
fn run() -> Result<std::process::ExitCode> {
    let mut msg = MSG::default();

    // C++: while((bRet = GetMessage(&msg, 0, 0, 0)) != 0)
    loop {
        // SAFETY: msg is a valid MSG for the OS to fill; no window filter.
        let ret = unsafe { GetMessageW(&mut msg, None, 0, 0) };
        match ret.0 {
            0 => break, // WM_QUIT received
            -1 => return Err(windows::core::Error::from_thread()), // C++: MessageBox "GetMessage FAILED"
            // SAFETY: msg was just filled by GetMessageW.
            _ => unsafe {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            },
        }
    }

    // C++: return (int)msg.wParam;   — the exit code passed to PostQuitMessage.
    Ok(std::process::ExitCode::from(msg.wParam.0 as u8))
}

/// C++: `LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)`
extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        // Handle left mouse button click message.
        WM_LBUTTONDOWN => {
            // SAFETY: FFI; None parent means the box is owned by the desktop.
            unsafe { MessageBoxW(None, w!("Hello, World"), w!("Hello"), MB_OK) };
            LRESULT(0)
        }

        // Handle key down message: destroy the window if the Escape key is pressed.
        WM_KEYDOWN => {
            if wparam.0 == VK_ESCAPE.0 as usize {
                // C++: DestroyWindow(ghMainWnd) — the callback's hwnd IS the main window,
                // so no global is needed.
                // SAFETY: hwnd is the valid window this callback was invoked for.
                unsafe { DestroyWindow(hwnd) }.expect("DestroyWindow failed");
            }
            LRESULT(0)
        }

        // Handle destroy window message: send a quit message, which will terminate the
        // message loop.
        WM_DESTROY => {
            // SAFETY: FFI with no preconditions; posts WM_QUIT to this thread's queue.
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }

        // Forward any other messages we did not handle to the default window procedure.
        // SAFETY: forwarding the exact arguments this callback received.
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}
