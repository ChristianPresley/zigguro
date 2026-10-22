//! Win32 handle, scalar and struct types shared by the bindings. Every
//! struct is `extern` with its size asserted for 64-bit Windows (x86_64
//! and aarch64 share the LLP64 layout); sizes are from the Windows SDK
//! headers. Bit flags stay plain integers with named constants.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// The calling convention of Win32 callbacks and COM methods: `.winapi`
/// on Windows, C elsewhere, where the types are only compiled and tested
/// (LLVM has no Windows ARM64 convention for aarch64-linux).
pub const winapi: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

/// A window.
pub const HWND = *opaque {};
/// A module (DLL or EXE) instance.
pub const HINSTANCE = *opaque {};
/// A module handle; the same as `HINSTANCE`.
pub const HMODULE = HINSTANCE;
/// A kernel object handle.
pub const HANDLE = *anyopaque;
/// An icon.
pub const HICON = *opaque {};
/// A cursor (an icon).
pub const HCURSOR = HICON;
/// A brush.
pub const HBRUSH = *opaque {};
/// A menu.
pub const HMENU = *opaque {};
/// A monitor.
pub const HMONITOR = *opaque {};
/// A device context.
pub const HDC = *opaque {};
/// A GDI object (bitmap, brush, ...).
pub const HGDIOBJ = *anyopaque;
/// A bitmap.
pub const HBITMAP = *opaque {};
/// Movable global memory (clipboard, drag & drop).
pub const HGLOBAL = *anyopaque;
/// An input method context.
pub const HIMC = *opaque {};
/// A raw input device or report.
pub const HRAWINPUT = *opaque {};
/// A keyboard layout.
pub const HKL = *opaque {};
/// A registry key.
pub const HKEY = *opaque {};
/// A drag & drop file list (`DragQueryFileW`).
pub const HDROP = *opaque {};
/// A DPI awareness context (a tagged pseudo-handle).
pub const DPI_AWARENESS_CONTEXT = *opaque {};

/// Message parameter (pointer sized, unsigned).
pub const WPARAM = usize;
/// Message parameter (pointer sized, signed).
pub const LPARAM = isize;
/// Window procedure result.
pub const LRESULT = isize;
/// A Win32 boolean (nonzero is true).
pub const BOOL = i32;
/// Unsigned 32-bit.
pub const UINT = u32;
/// Unsigned 32-bit.
pub const DWORD = u32;
/// Unsigned 32-bit (COM counts).
pub const ULONG = u32;
/// Signed 32-bit.
pub const LONG = i32;
/// Unsigned 16-bit.
pub const WORD = u16;
/// A registered class atom.
pub const ATOM = u16;
/// A COM status code.
pub const HRESULT = i32;
/// A NUL-terminated UTF-16 string.
pub const LPCWSTR = [*:0]const u16;
/// A writable NUL-terminated UTF-16 string.
pub const LPWSTR = [*:0]u16;
/// A clipboard format id.
pub const CLIPFORMAT = u16;

/// Win32 `TRUE`.
pub const TRUE: BOOL = 1;
/// Win32 `FALSE`.
pub const FALSE: BOOL = 0;

/// `S_OK`.
pub const S_OK: HRESULT = 0;
/// `S_FALSE`.
pub const S_FALSE: HRESULT = 1;
/// `E_NOINTERFACE`.
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
/// `E_POINTER`.
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
/// `E_NOTIMPL`.
pub const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
/// `E_FAIL`.
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
/// `E_OUTOFMEMORY`.
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
/// `E_INVALIDARG`.
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
/// `DV_E_FORMATETC`: unsupported clipboard/drag format.
pub const DV_E_FORMATETC: HRESULT = @bitCast(@as(u32, 0x80040064));
/// `DRAGDROP_S_DROP`.
pub const DRAGDROP_S_DROP: HRESULT = 0x00040100;
/// `DRAGDROP_S_CANCEL`.
pub const DRAGDROP_S_CANCEL: HRESULT = 0x00040101;
/// `DRAGDROP_S_USEDEFAULTCURSORS`.
pub const DRAGDROP_S_USEDEFAULTCURSORS: HRESULT = 0x00040102;

/// Whether an `HRESULT` is a success code.
pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

/// `RECT`.
pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
/// `POINT`.
pub const POINT = extern struct { x: i32, y: i32 };
/// `POINTL` (drag & drop coordinates).
pub const POINTL = POINT;
/// `SIZE`.
pub const SIZE = extern struct { cx: i32, cy: i32 };

/// `MSG`.
pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

/// A window procedure.
pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(winapi) LRESULT;
/// A `SetTimer` callback.
pub const TIMERPROC = *const fn (?HWND, UINT, usize, DWORD) callconv(winapi) void;
/// An `EnumDisplayMonitors` callback.
pub const MONITORENUMPROC = *const fn (HMONITOR, ?HDC, *RECT, LPARAM) callconv(winapi) BOOL;

/// `WNDCLASSEXW`.
pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

/// `WINDOWPOS`.
pub const WINDOWPOS = extern struct {
    hwnd: ?HWND,
    hwndInsertAfter: ?HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: UINT,
};

/// `NCCALCSIZE_PARAMS` (WM_NCCALCSIZE with wParam TRUE).
pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: ?*WINDOWPOS,
};

/// `MINMAXINFO` (WM_GETMINMAXINFO).
pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

/// `MONITORINFOEXW`.
pub const MONITORINFOEXW = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFOEXW),
    rcMonitor: RECT = std.mem.zeroes(RECT),
    rcWork: RECT = std.mem.zeroes(RECT),
    dwFlags: DWORD = 0,
    szDevice: [32]u16 = @splat(0),
};

/// `TRACKMOUSEEVENT`.
pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD = 0,
};

/// `FLASHWINFO`.
pub const FLASHWINFO = extern struct {
    cbSize: UINT = @sizeOf(FLASHWINFO),
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD,
};

/// `ICONINFO` (cursor bitmaps for `CreateIconIndirect`).
pub const ICONINFO = extern struct {
    fIcon: BOOL,
    xHotspot: DWORD,
    yHotspot: DWORD,
    hbmMask: ?HBITMAP,
    hbmColor: ?HBITMAP,
};

/// `PAINTSTRUCT`.
pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

/// `BITMAPINFOHEADER`.
pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: WORD = 1,
    biBitCount: WORD,
    biCompression: DWORD = 0,
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: LONG = 0,
    biYPelsPerMeter: LONG = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

/// `BITMAPINFO` with one (unused for 32 bpp) color entry.
pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};

/// `COMPOSITIONFORM` (`ImmSetCompositionWindow`).
pub const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

/// `CANDIDATEFORM` (`ImmSetCandidateWindow`).
pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD,
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

/// `RAWINPUTDEVICE`.
pub const RAWINPUTDEVICE = extern struct {
    usUsagePage: u16,
    usUsage: u16,
    dwFlags: DWORD,
    hwndTarget: ?HWND,
};

/// `RAWINPUTHEADER`.
pub const RAWINPUTHEADER = extern struct {
    dwType: DWORD,
    dwSize: DWORD,
    hDevice: ?HANDLE,
    wParam: WPARAM,
};

/// `RAWMOUSE`; `usButtonFlags`/`usButtonData` overlay `ulButtons`.
pub const RAWMOUSE = extern struct {
    usFlags: u16,
    _pad: u16 = 0,
    usButtonFlags: u16,
    usButtonData: u16,
    ulRawButtons: ULONG,
    lLastX: LONG,
    lLastY: LONG,
    ulExtraInformation: ULONG,
};

/// `RAWKEYBOARD`.
pub const RAWKEYBOARD = extern struct {
    MakeCode: u16,
    Flags: u16,
    Reserved: u16,
    VKey: u16,
    Message: UINT,
    ExtraInformation: ULONG,
};

/// `RAWINPUT` for mouse and keyboard devices.
pub const RAWINPUT = extern struct {
    header: RAWINPUTHEADER,
    data: extern union {
        mouse: RAWMOUSE,
        keyboard: RAWKEYBOARD,
    },
};

/// `POINTER_INFO` (WM_POINTER*).
pub const POINTER_INFO = extern struct {
    pointerType: DWORD,
    pointerId: UINT,
    frameId: UINT,
    pointerFlags: DWORD,
    sourceDevice: ?HANDLE,
    hwndTarget: ?HWND,
    ptPixelLocation: POINT,
    ptHimetricLocation: POINT,
    ptPixelLocationRaw: POINT,
    ptHimetricLocationRaw: POINT,
    dwTime: DWORD,
    historyCount: UINT,
    InputData: i32,
    dwKeyStates: DWORD,
    PerformanceCount: u64,
    ButtonChangeType: i32,
};

/// `POINTER_PEN_INFO`.
pub const POINTER_PEN_INFO = extern struct {
    pointerInfo: POINTER_INFO,
    penFlags: DWORD,
    penMask: DWORD,
    pressure: UINT,
    rotation: UINT,
    tiltX: i32,
    tiltY: i32,
};

/// `GUID` (also IID and CLSID).
pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    /// Whether two GUIDs are equal.
    pub fn eql(a: *const GUID, b: *const GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
    }
};

/// `DVTARGETDEVICE` (only ever passed as null).
pub const DVTARGETDEVICE = opaque {};

/// `FORMATETC`.
pub const FORMATETC = extern struct {
    cfFormat: CLIPFORMAT,
    ptd: ?*DVTARGETDEVICE = null,
    dwAspect: DWORD = 1, // DVASPECT_CONTENT
    lindex: LONG = -1,
    tymed: DWORD,
};

/// `STGMEDIUM` with an `HGLOBAL` (the only medium we produce).
pub const STGMEDIUM = extern struct {
    tymed: DWORD,
    u: extern union { hGlobal: ?HGLOBAL, pointer: ?*anyopaque },
    pUnkForRelease: ?*anyopaque,
};

/// `DROPFILES` header of a `CF_HDROP` block.
pub const DROPFILES = extern struct {
    pFiles: DWORD,
    pt: POINT,
    fNC: BOOL,
    fWide: BOOL,
};

/// `MARGINS` (`DwmExtendFrameIntoClientArea`).
pub const MARGINS = extern struct {
    cxLeftWidth: i32,
    cxRightWidth: i32,
    cyTopHeight: i32,
    cyBottomHeight: i32,
};

/// `UNSIGNED_RATIO`.
pub const UNSIGNED_RATIO = extern struct { uiNumerator: u32, uiDenominator: u32 };

/// `DWM_TIMING_INFO`, declared under `#pragma pack(1)` in dwmapi.h.
pub const DWM_TIMING_INFO = extern struct {
    cbSize: u32 align(1) = @sizeOf(DWM_TIMING_INFO),
    rateRefresh: UNSIGNED_RATIO align(1) = .{ .uiNumerator = 0, .uiDenominator = 0 },
    qpcRefreshPeriod: u64 align(1) = 0,
    rateCompose: UNSIGNED_RATIO align(1) = .{ .uiNumerator = 0, .uiDenominator = 0 },
    qpcVBlank: u64 align(1) = 0,
    cRefresh: u64 align(1) = 0,
    cDXRefresh: u32 align(1) = 0,
    qpcCompose: u64 align(1) = 0,
    cFrame: u64 align(1) = 0,
    cDXPresent: u32 align(1) = 0,
    cRefreshFrame: u64 align(1) = 0,
    cFrameSubmitted: u64 align(1) = 0,
    cDXPresentSubmitted: u32 align(1) = 0,
    cFrameConfirmed: u64 align(1) = 0,
    cDXPresentConfirmed: u32 align(1) = 0,
    cRefreshConfirmed: u64 align(1) = 0,
    cDXRefreshConfirmed: u32 align(1) = 0,
    cFramesLate: u64 align(1) = 0,
    cFramesOutstanding: u32 align(1) = 0,
    cFrameDisplayed: u64 align(1) = 0,
    qpcFrameDisplayed: u64 align(1) = 0,
    cRefreshFrameDisplayed: u64 align(1) = 0,
    cFrameComplete: u64 align(1) = 0,
    qpcFrameComplete: u64 align(1) = 0,
    cFramePending: u64 align(1) = 0,
    qpcFramePending: u64 align(1) = 0,
    cFramesDisplayed: u64 align(1) = 0,
    cFramesComplete: u64 align(1) = 0,
    cFramesPending: u64 align(1) = 0,
    cFramesAvailable: u64 align(1) = 0,
    cFramesDropped: u64 align(1) = 0,
    cFramesMissed: u64 align(1) = 0,
    cRefreshNextDisplayed: u64 align(1) = 0,
    cRefreshNextPresented: u64 align(1) = 0,
    cRefreshesDisplayed: u64 align(1) = 0,
    cRefreshesPresented: u64 align(1) = 0,
    cRefreshStarted: u64 align(1) = 0,
    cPixelsReceived: u64 align(1) = 0,
    cPixelsDrawn: u64 align(1) = 0,
    cBuffersEmpty: u64 align(1) = 0,
};

/// `PROCESSENTRY32W` (Toolhelp snapshots; E06 foreground process).
pub const PROCESSENTRY32W = extern struct {
    dwSize: DWORD = @sizeOf(PROCESSENTRY32W),
    cntUsage: DWORD = 0,
    th32ProcessID: DWORD = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: DWORD = 0,
    cntThreads: DWORD = 0,
    th32ParentProcessID: DWORD = 0,
    pcPriClassBase: LONG = 0,
    dwFlags: DWORD = 0,
    szExeFile: [260]u16 = @splat(0),
};

/// `COMDLG_FILTERSPEC` (`IFileDialog.SetFileTypes`).
pub const COMDLG_FILTERSPEC = extern struct { pszName: LPCWSTR, pszSpec: LPCWSTR };

/// A pseudoconsole (`CreatePseudoConsole`).
pub const HPCON = *opaque {};

/// `COORD`.
pub const COORD = extern struct { X: i16, Y: i16 };

/// `SECURITY_ATTRIBUTES`.
pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = 0,
};

/// `STARTUPINFOW`.
pub const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?LPCWSTR = null,
    lpDesktop: ?LPCWSTR = null,
    lpTitle: ?LPCWSTR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: WORD = 0,
    cbReserved2: WORD = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

/// `STARTUPINFOEXW`.
pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque = null,
};

/// `OVERLAPPED`.
pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

/// `FILE_NOTIFY_INFORMATION`'s fixed part; the UTF-16 name follows.
pub const FILE_NOTIFY_INFORMATION = extern struct {
    NextEntryOffset: DWORD,
    Action: DWORD,
    FileNameLength: DWORD,
};

/// `PROCESS_INFORMATION`.
pub const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE = null,
    hThread: ?HANDLE = null,
    dwProcessId: DWORD = 0,
    dwThreadId: DWORD = 0,
};

/// `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` (with its basic limits and I/O
/// counters inlined).
pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: DWORD = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: DWORD = 0,
    Affinity: usize = 0,
    PriorityClass: DWORD = 0,
    SchedulingClass: DWORD = 0,
    IoCounters: [6]u64 = @splat(0),
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

/// Struct sizes for 64-bit Windows, from the SDK headers.
const sizes_64 = .{
    .{ RECT, 16 },                                  .{ POINT, 8 },              .{ MSG, 48 },
    .{ WNDCLASSEXW, 80 },                           .{ WINDOWPOS, 40 },         .{ NCCALCSIZE_PARAMS, 56 },
    .{ MINMAXINFO, 40 },                            .{ MONITORINFOEXW, 104 },   .{ TRACKMOUSEEVENT, 24 },
    .{ FLASHWINFO, 32 },                            .{ ICONINFO, 32 },          .{ PAINTSTRUCT, 72 },
    .{ BITMAPINFOHEADER, 40 },                      .{ BITMAPINFO, 44 },        .{ COMPOSITIONFORM, 28 },
    .{ CANDIDATEFORM, 32 },                         .{ RAWINPUTDEVICE, 16 },    .{ RAWINPUTHEADER, 24 },
    .{ RAWMOUSE, 24 },                              .{ RAWKEYBOARD, 16 },       .{ RAWINPUT, 48 },
    .{ POINTER_INFO, 96 },                          .{ POINTER_PEN_INFO, 120 }, .{ GUID, 16 },
    .{ FORMATETC, 32 },                             .{ STGMEDIUM, 24 },         .{ DROPFILES, 20 },
    .{ MARGINS, 16 },                               .{ DWM_TIMING_INFO, 292 },  .{ PROCESSENTRY32W, 568 },
    .{ COMDLG_FILTERSPEC, 16 },                     .{ COORD, 4 },              .{ SECURITY_ATTRIBUTES, 24 },
    .{ STARTUPINFOW, 104 },                         .{ STARTUPINFOEXW, 112 },   .{ PROCESS_INFORMATION, 24 },
    .{ JOBOBJECT_EXTENDED_LIMIT_INFORMATION, 144 },
};

comptime {
    if (@sizeOf(usize) == 8) {
        for (sizes_64) |e| {
            if (@sizeOf(e[0]) != e[1]) @compileError(std.fmt.comptimePrint("{s}: size {d}, expected {d}", .{ @typeName(e[0]), @sizeOf(e[0]), e[1] }));
        }
        assert(@offsetOf(MSG, "pt") == 36);
        assert(@offsetOf(RAWMOUSE, "usButtonFlags") == 4);
        assert(@offsetOf(RAWINPUT, "data") == 24);
        assert(@offsetOf(POINTER_INFO, "PerformanceCount") == 80);
        assert(@offsetOf(FORMATETC, "ptd") == 8);
        assert(@offsetOf(STGMEDIUM, "u") == 8);
    }
}

test "struct sizes" {
    // The comptime block above holds the assertions; this pulls it in.
    try std.testing.expectEqual(48, @sizeOf(MSG));
    try std.testing.expect(succeeded(S_FALSE) and !succeeded(E_FAIL));
}
