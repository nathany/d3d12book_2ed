// Port of the book's Appendix A sample (`InitWindowsApp` — the "Hello, World" Win32
// window). The 2nd edition's source ships no Appendix A demo, so this follows the program
// printed in the appendix text, using the same conventions `Common/d3dApp.cpp` uses for the
// real window in chapter 4 (plain WNDCLASS, default icon/cursor, CreateWindow).
//
// Behavior, per the book: a white window titled "Win32Basic"; left-click shows a
// "Hello, World" message box; Escape destroys the window and the app exits cleanly.
//
// Build & run: odin run odin_port/APPENDIX_A
//
// Win32 → core:sys/windows, the Appendix A differences:
//
//  - WinMain → plain main. No nShowCmd (we pass SW_SHOW), and the console subsystem is
//    kept deliberately — from chapter 4 on, debug-layer messages go to stderr. (Ship
//    builds would pass -subsystem:windows.)
//  - Wide APIs: core:sys/windows binds the W variants. windows.L("…") builds a UTF-16
//    literal at compile time (the C++ gets the same via L"…"); runtime strings go through
//    windows.utf8_to_wstring (temp allocator).
//  - The WndProc is `proc "system"` — the required calling convention. A "system" proc has
//    NO Odin context; this one never needs it, but the moment one calls fmt/allocators it
//    must first do `context = runtime.default_context()`.
//  - The book's global ghMainWnd disappears — the callback's own hwnd parameter is the same
//    window, so DestroyWindow(hwnd) replaces it. (Chapter 4's D3DApp genuinely needs app
//    state in the WndProc; that plumbing arrives there.)
//  - Error convention (same as the Rust port): fatal errors are reported BOTH ways —
//    stderr for consoles/CI, a message box for a human running the windowed app (the
//    book's MessageBox(0, L"…FAILED", 0, 0) style), centralized in report_error.
//  - The appendix uses the blocking GetMessage loop (ported below, including the book's
//    -1 error check — GetMessageW returns INT here, so the check ports directly);
//    chapter 4 switches to PeekMessage for the game loop.
package appendix_a

import "core:fmt"
import "core:os"
import win "core:sys/windows"

// C++: int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE, PSTR, int nShowCmd)
main :: proc() {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))

	// C++: if(!InitWindowsApp(hInstance, nShowCmd)) return 0;
	if !init_windows_app(instance, win.SW_SHOW) {
		os.exit(1)
	}

	// C++: return Run();
	os.exit(int(run()))
}

// C++: bool InitWindowsApp(HINSTANCE instanceHandle, int show)
init_windows_app :: proc(instance: win.HINSTANCE, show: win.c_int) -> bool {
	// The first task to creating a window is to describe some of its characteristics by
	// filling out a WNDCLASS structure.
	wc := win.WNDCLASSW {
		style         = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc   = wnd_proc,
		cbClsExtra    = 0,
		cbWndExtra    = 0,
		hInstance     = instance,
		// IDI_APPLICATION/IDC_ARROW are MAKEINTRESOURCE fake pointers (integer 32512);
		// core:sys/windows types them as cstring, so cast for the W functions.
		hIcon         = win.LoadIconW(nil, win.LPCWSTR(win._IDI_APPLICATION)),
		hCursor       = win.LoadCursorW(nil, win.LPCWSTR(win._IDC_ARROW)),
		// C++: (HBRUSH)GetStockObject(WHITE_BRUSH) — same cast, Odin spelling.
		hbrBackground = win.HBRUSH(win.GetStockObject(win.WHITE_BRUSH)),
		lpszMenuName  = nil,
		lpszClassName = win.L("BasicWndClass"),
	}

	// Next, we register this WNDCLASS instance with Windows so that we can create a
	// window based on it.
	if win.RegisterClassW(&wc) == 0 {
		report_error("RegisterClass FAILED") // C++: MessageBox(0, L"RegisterClass FAILED", 0, 0);
		return false
	}

	// With our WNDCLASS instance registered, we can create a window with the CreateWindow
	// function.
	hwnd := win.CreateWindowExW(
		0,                        // dwExStyle (the C++ calls plain CreateWindow = ExStyle 0)
		win.L("BasicWndClass"),   // Registered WNDCLASS instance to use.
		win.L("Win32Basic"),      // window title
		win.WS_OVERLAPPEDWINDOW,  // style flags
		win.CW_USEDEFAULT,        // x-coordinate
		win.CW_USEDEFAULT,        // y-coordinate
		win.CW_USEDEFAULT,        // width
		win.CW_USEDEFAULT,        // height
		nil,                      // parent window
		nil,                      // menu handle
		instance,                 // app instance
		nil,                      // extra creation parameters
	)
	if hwnd == nil {
		report_error("CreateWindow FAILED") // C++: MessageBox(0, L"CreateWindow FAILED", 0, 0);
		return false
	}

	// Even though we just created a window, it is not initially shown. UpdateWindow sends
	// WM_PAINT straight to the WndProc (bypassing the queue) so the first paint happens
	// now — classic GDI boilerplate; moot from ch 4 on, where the game loop renders every
	// frame itself.
	win.ShowWindow(hwnd, show) // C++: ShowWindow(ghMainWnd, show);
	win.UpdateWindow(hwnd)

	return true
}

// C++: int Run() — the blocking GetMessage loop, including the book's -1 error check.
run :: proc() -> win.WPARAM {
	msg: win.MSG

	// C++: while((bRet = GetMessage(&msg, 0, 0, 0)) != 0)
	for {
		ret := win.GetMessageW(&msg, nil, 0, 0)
		switch ret {
		case 0: // WM_QUIT received
			return msg.wParam // C++: return (int)msg.wParam;
		case -1:
			report_error("GetMessage FAILED") // C++: MessageBox(0, L"GetMessage FAILED", L"Error", MB_OK);
			return 1
		case:
			win.TranslateMessage(&msg)
			win.DispatchMessageW(&msg)
		}
	}
}

// C++: LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
wnd_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	switch msg {
	// Handle left mouse button click message.
	case win.WM_LBUTTONDOWN:
		win.MessageBoxW(nil, win.L("Hello, World"), win.L("Hello"), win.MB_OK)
		return 0

	// Handle key down message: destroy the window if the Escape key is pressed.
	case win.WM_KEYDOWN:
		if wparam == win.VK_ESCAPE {
			// C++: DestroyWindow(ghMainWnd) — the callback's hwnd IS the main window,
			// so no global is needed.
			win.DestroyWindow(hwnd)
		}
		return 0

	// Handle destroy window message: send a quit message, which will terminate the
	// message loop.
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		return 0
	}

	// Forward any other messages we did not handle to the default window procedure.
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

// Fatal-error reporting, both channels (port convention — see the guides): stderr for
// consoles/CI, a message box for a human running the windowed app.
report_error :: proc(what: string) {
	err := win.GetLastError()
	fmt.eprintfln("fatal error: %s (GetLastError = %v)", what, err)
	text := win.utf8_to_wstring(fmt.tprintf("%s (error %v)", what, err))
	win.MessageBoxW(nil, text, win.L("Error"), win.MB_OK | win.MB_ICONERROR)
}
