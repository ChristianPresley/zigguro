//! user32: windows, messages, DPI, monitors, input, clipboard, cursors and
//! painting. `extern "user32"` makes Zig link the import library itself.
//!
//! planned: E01.F02.S01.T02 (pump, windows, DPI, monitors), E01.F02.S01.T03
//! (frame, cursors), E01.F02.S02.T01 (input), E01.F02.S04.T01 (clipboard),
//! E01.F02.S05.T01 (painting).

const t = @import("types.zig");
const HWND = t.HWND;
const UINT = t.UINT;
const DWORD = t.DWORD;
const BOOL = t.BOOL;
const WPARAM = t.WPARAM;
const LPARAM = t.LPARAM;
const LRESULT = t.LRESULT;
const LPCWSTR = t.LPCWSTR;
const HANDLE = t.HANDLE;
const RECT = t.RECT;
const POINT = t.POINT;

/// `PeekMessageW`: remove the message.
pub const PM_REMOVE: UINT = 0x0001;
/// `MsgWaitForMultipleObjectsEx`: any input or posted message.
pub const QS_ALLINPUT: DWORD = 0x04FF;
/// `MsgWaitForMultipleObjectsEx`: return if input is already queued.
pub const MWMO_INPUTAVAILABLE: DWORD = 0x0004;
/// `CreateWindowExW`: let the system pick.
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
/// `WS_OVERLAPPEDWINDOW`.
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
/// `WS_EX_NOREDIRECTIONBITMAP` (GPU-presented windows).
pub const WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x00200000;
/// `HWND_MESSAGE`: parent of message-only windows.
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
/// `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`.
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: t.DPI_AWARENESS_CONTEXT = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));
/// `USER_DEFAULT_SCREEN_DPI`.
pub const USER_DEFAULT_SCREEN_DPI: UINT = 96;

/// Registers a window class.
pub extern "user32" fn RegisterClassExW(*const t.WNDCLASSEXW) callconv(.winapi) t.ATOM;
/// Creates a window.
pub extern "user32" fn CreateWindowExW(ex: DWORD, cls: ?LPCWSTR, name: ?LPCWSTR, style: DWORD, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?t.HMENU, inst: ?t.HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
/// Destroys a window.
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
/// The default window procedure.
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
/// Takes a message from the queue without waiting.
pub extern "user32" fn PeekMessageW(msg: *t.MSG, hwnd: ?HWND, min: UINT, max: UINT, remove: UINT) callconv(.winapi) BOOL;
/// Produces WM_CHAR from key messages.
pub extern "user32" fn TranslateMessage(*const t.MSG) callconv(.winapi) BOOL;
/// Calls the window procedure for a message.
pub extern "user32" fn DispatchMessageW(*const t.MSG) callconv(.winapi) LRESULT;
/// Posts a message to a window's thread.
pub extern "user32" fn PostMessageW(?HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
/// Sends a message and waits for the window's thread to handle it.
pub extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
/// Unregisters a window class.
pub extern "user32" fn UnregisterClassW(LPCWSTR, ?t.HINSTANCE) callconv(.winapi) BOOL;
/// Paints the window's update region now (sends WM_PAINT).
pub extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
/// Waits for handles or queued input.
pub extern "user32" fn MsgWaitForMultipleObjectsEx(n: DWORD, handles: ?[*]const HANDLE, ms: DWORD, wake: DWORD, flags: DWORD) callconv(.winapi) DWORD;
/// Stores a pointer-sized value in a window (GWLP_USERDATA).
pub extern "user32" fn SetWindowLongPtrW(HWND, index: i32, value: isize) callconv(.winapi) isize;
/// Reads a pointer-sized window value.
pub extern "user32" fn GetWindowLongPtrW(HWND, index: i32) callconv(.winapi) isize;
/// Moves, sizes and orders a window.
pub extern "user32" fn SetWindowPos(HWND, after: ?HWND, x: i32, y: i32, cx: i32, cy: i32, flags: UINT) callconv(.winapi) BOOL;
/// Shows, hides, minimizes or maximizes a window.
pub extern "user32" fn ShowWindow(HWND, cmd: i32) callconv(.winapi) BOOL;
/// Sets the title.
pub extern "user32" fn SetWindowTextW(HWND, LPCWSTR) callconv(.winapi) BOOL;
/// The client area in client coordinates.
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
/// The window rectangle in screen coordinates.
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
/// Converts a client point to screen coordinates.
pub extern "user32" fn ClientToScreen(HWND, *POINT) callconv(.winapi) BOOL;
/// Converts a screen point to client coordinates.
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
/// Brings a window to the foreground.
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
/// Lets another process take the foreground.
pub extern "user32" fn AllowSetForegroundWindow(pid: DWORD) callconv(.winapi) BOOL;
/// Flashes the taskbar button.
pub extern "user32" fn FlashWindowEx(*const t.FLASHWINFO) callconv(.winapi) BOOL;
/// Invalidates part of a window.
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;

/// Sets the process DPI awareness.
pub extern "user32" fn SetProcessDpiAwarenessContext(t.DPI_AWARENESS_CONTEXT) callconv(.winapi) BOOL;
/// The calling thread's DPI awareness context.
pub extern "user32" fn GetThreadDpiAwarenessContext() callconv(.winapi) t.DPI_AWARENESS_CONTEXT;
/// The awareness value of a context (2 = per monitor).
pub extern "user32" fn GetAwarenessFromDpiAwarenessContext(t.DPI_AWARENESS_CONTEXT) callconv(.winapi) i32;
/// Whether two awareness contexts are equivalent.
pub extern "user32" fn AreDpiAwarenessContextsEqual(t.DPI_AWARENESS_CONTEXT, t.DPI_AWARENESS_CONTEXT) callconv(.winapi) BOOL;
/// A window's DPI.
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
/// The outer rectangle for a client rectangle at a DPI.
pub extern "user32" fn AdjustWindowRectExForDpi(*RECT, style: DWORD, menu: BOOL, ex: DWORD, dpi: UINT) callconv(.winapi) BOOL;
/// A system metric at a DPI.
pub extern "user32" fn GetSystemMetricsForDpi(index: i32, dpi: UINT) callconv(.winapi) i32;
/// A system parameter at a DPI.
pub extern "user32" fn SystemParametersInfoForDpi(action: UINT, param: UINT, pv: ?*anyopaque, win_ini: UINT, dpi: UINT) callconv(.winapi) BOOL;
/// A system parameter (reduced motion, caret width, ...).
pub extern "user32" fn SystemParametersInfoW(action: UINT, param: UINT, pv: ?*anyopaque, win_ini: UINT) callconv(.winapi) BOOL;
/// Calls `proc` for each monitor.
pub extern "user32" fn EnumDisplayMonitors(?t.HDC, ?*const RECT, proc: t.MONITORENUMPROC, LPARAM) callconv(.winapi) BOOL;
/// A monitor's rectangles and device name.
pub extern "user32" fn GetMonitorInfoW(t.HMONITOR, *t.MONITORINFOEXW) callconv(.winapi) BOOL;
/// The monitor a window is mostly on.
pub extern "user32" fn MonitorFromWindow(HWND, flags: DWORD) callconv(.winapi) ?t.HMONITOR;
/// The double-click interval in milliseconds.
pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) UINT;

/// Loads a system cursor (`IDC_*` as an integer resource).
pub extern "user32" fn LoadCursorW(?t.HINSTANCE, name: *const anyopaque) callconv(.winapi) ?t.HCURSOR;
/// Sets the cursor shape.
pub extern "user32" fn SetCursor(?t.HCURSOR) callconv(.winapi) ?t.HCURSOR;
/// Creates a cursor or icon from bitmaps.
pub extern "user32" fn CreateIconIndirect(*const t.ICONINFO) callconv(.winapi) ?t.HICON;
/// Destroys a cursor made by `CreateIconIndirect`.
pub extern "user32" fn DestroyCursor(t.HCURSOR) callconv(.winapi) BOOL;
/// Captures the mouse.
pub extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
/// Releases the mouse capture.
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
/// Requests WM_MOUSELEAVE/WM_MOUSEHOVER.
pub extern "user32" fn TrackMouseEvent(*t.TRACKMOUSEEVENT) callconv(.winapi) BOOL;

/// Registers raw input devices.
pub extern "user32" fn RegisterRawInputDevices(devices: [*]const t.RAWINPUTDEVICE, n: UINT, size: UINT) callconv(.winapi) BOOL;
/// Reads one WM_INPUT report.
pub extern "user32" fn GetRawInputData(t.HRAWINPUT, cmd: UINT, data: ?*anyopaque, size: *UINT, header_size: UINT) callconv(.winapi) UINT;
/// Reads buffered raw input reports.
pub extern "user32" fn GetRawInputBuffer(data: ?*t.RAWINPUT, size: *UINT, header_size: UINT) callconv(.winapi) UINT;
/// The 256-key state array.
pub extern "user32" fn GetKeyboardState(state: *[256]u8) callconv(.winapi) BOOL;
/// One key's state (high bit = down).
pub extern "user32" fn GetKeyState(vk: i32) callconv(.winapi) i16;
/// Translates a key to UTF-16 in a layout.
pub extern "user32" fn ToUnicodeEx(vk: UINT, scan: UINT, state: *const [256]u8, buf: [*]u16, n: i32, flags: UINT, layout: ?t.HKL) callconv(.winapi) i32;
/// A thread's keyboard layout.
pub extern "user32" fn GetKeyboardLayout(thread: DWORD) callconv(.winapi) ?t.HKL;
/// Maps between virtual keys and scan codes.
pub extern "user32" fn MapVirtualKeyExW(code: UINT, map_type: UINT, layout: ?t.HKL) callconv(.winapi) UINT;
/// Pointer (pen/touch/mouse) details for WM_POINTER*.
pub extern "user32" fn GetPointerInfo(id: UINT, info: *t.POINTER_INFO) callconv(.winapi) BOOL;
/// Routes mouse input through WM_POINTER.
pub extern "user32" fn EnableMouseInPointer(BOOL) callconv(.winapi) BOOL;

/// Opens the clipboard.
pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
/// Closes the clipboard.
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
/// Takes clipboard ownership and clears it.
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
/// Reads clipboard data in a format.
pub extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) ?HANDLE;
/// Puts data (or null for delayed rendering) on the clipboard.
pub extern "user32" fn SetClipboardData(format: UINT, data: ?HANDLE) callconv(.winapi) ?HANDLE;
/// Registers a named clipboard format ("HTML Format").
pub extern "user32" fn RegisterClipboardFormatW(LPCWSTR) callconv(.winapi) UINT;
/// Whether the clipboard has a format.
pub extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;
/// Subscribes a window to WM_CLIPBOARDUPDATE.
pub extern "user32" fn AddClipboardFormatListener(HWND) callconv(.winapi) BOOL;
/// The window's system (window) menu.
pub extern "user32" fn GetSystemMenu(HWND, revert: BOOL) callconv(.winapi) ?t.HMENU;
/// Shows a popup menu; with `TPM_RETURNCMD` it returns the chosen command.
pub extern "user32" fn TrackPopupMenu(t.HMENU, flags: UINT, x: i32, y: i32, reserved: i32, HWND, ?*const RECT) callconv(.winapi) BOOL;
/// Whether the window is maximized.
pub extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
/// Whether the window is minimized.
pub extern "user32" fn IsIconic(HWND) callconv(.winapi) BOOL;
/// Unsubscribes a window from WM_CLIPBOARDUPDATE.
pub extern "user32" fn RemoveClipboardFormatListener(HWND) callconv(.winapi) BOOL;
/// The window that owns the clipboard.
pub extern "user32" fn GetClipboardOwner() callconv(.winapi) ?HWND;

/// Starts a timer.
pub extern "user32" fn SetTimer(?HWND, id: usize, ms: UINT, proc: ?t.TIMERPROC) callconv(.winapi) usize;
/// Stops a timer.
pub extern "user32" fn KillTimer(?HWND, id: usize) callconv(.winapi) BOOL;

/// A window's device context.
pub extern "user32" fn GetDC(?HWND) callconv(.winapi) ?t.HDC;
/// Releases a `GetDC` context.
pub extern "user32" fn ReleaseDC(?HWND, t.HDC) callconv(.winapi) i32;
/// Starts WM_PAINT handling.
pub extern "user32" fn BeginPaint(HWND, *t.PAINTSTRUCT) callconv(.winapi) ?t.HDC;
/// Ends WM_PAINT handling.
pub extern "user32" fn EndPaint(HWND, *const t.PAINTSTRUCT) callconv(.winapi) BOOL;

/// `MAKEINTRESOURCEW` for `LoadCursorW` (`IDC_ARROW` is 32512). Typed as
/// `anyopaque` because odd ids are not valid UTF-16 pointers.
pub fn makeIntResource(id: u16) *const anyopaque {
    return @ptrFromInt(@as(usize, id));
}
