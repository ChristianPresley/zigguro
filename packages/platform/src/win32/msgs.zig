//! Win32 message numbers, window styles and other constants the backend
//! uses, from WinUser.h and WinGDI.h. Values only; they build on every OS.

/// `WM_*` window messages.
pub const WM = struct {
    /// WM_CREATE.
    pub const CREATE: u32 = 0x0001;
    /// WM_DESTROY.
    pub const DESTROY: u32 = 0x0002;
    /// WM_MOVE.
    pub const MOVE: u32 = 0x0003;
    /// WM_SIZE.
    pub const SIZE: u32 = 0x0005;
    /// WM_ACTIVATE.
    pub const ACTIVATE: u32 = 0x0006;
    /// WM_SETFOCUS.
    pub const SETFOCUS: u32 = 0x0007;
    /// WM_KILLFOCUS.
    pub const KILLFOCUS: u32 = 0x0008;
    /// WM_PAINT.
    pub const PAINT: u32 = 0x000F;
    /// WM_CLOSE.
    pub const CLOSE: u32 = 0x0010;
    /// WM_QUIT.
    pub const QUIT: u32 = 0x0012;
    /// WM_ERASEBKGND.
    pub const ERASEBKGND: u32 = 0x0014;
    /// WM_SETCURSOR.
    pub const SETCURSOR: u32 = 0x0020;
    /// WM_GETMINMAXINFO.
    pub const GETMINMAXINFO: u32 = 0x0024;
    /// WM_DISPLAYCHANGE.
    pub const DISPLAYCHANGE: u32 = 0x007E;
    /// WM_NCCREATE.
    pub const NCCREATE: u32 = 0x0081;
    /// WM_NCCALCSIZE.
    pub const NCCALCSIZE: u32 = 0x0083;
    /// WM_NCHITTEST.
    pub const NCHITTEST: u32 = 0x0084;
    /// WM_NCMOUSEMOVE.
    pub const NCMOUSEMOVE: u32 = 0x00A0;
    /// WM_NCLBUTTONDOWN.
    pub const NCLBUTTONDOWN: u32 = 0x00A1;
    /// WM_NCLBUTTONUP.
    pub const NCLBUTTONUP: u32 = 0x00A2;
    /// WM_INPUTLANGCHANGE.
    pub const INPUTLANGCHANGE: u32 = 0x0051;
    /// WM_KEYDOWN.
    pub const KEYDOWN: u32 = 0x0100;
    /// WM_KEYUP.
    pub const KEYUP: u32 = 0x0101;
    /// WM_CHAR.
    pub const CHAR: u32 = 0x0102;
    /// WM_SYSKEYDOWN.
    pub const SYSKEYDOWN: u32 = 0x0104;
    /// WM_SYSKEYUP.
    pub const SYSKEYUP: u32 = 0x0105;
    /// WM_SYSCHAR.
    pub const SYSCHAR: u32 = 0x0106;
    /// WM_SYSCOMMAND.
    pub const SYSCOMMAND: u32 = 0x0112;
    /// WM_TIMER.
    pub const TIMER: u32 = 0x0113;
    /// WM_MOUSEMOVE.
    pub const MOUSEMOVE: u32 = 0x0200;
    /// WM_LBUTTONDOWN.
    pub const LBUTTONDOWN: u32 = 0x0201;
    /// WM_LBUTTONUP.
    pub const LBUTTONUP: u32 = 0x0202;
    /// WM_RBUTTONDOWN.
    pub const RBUTTONDOWN: u32 = 0x0204;
    /// WM_RBUTTONUP.
    pub const RBUTTONUP: u32 = 0x0205;
    /// WM_MBUTTONDOWN.
    pub const MBUTTONDOWN: u32 = 0x0207;
    /// WM_MBUTTONUP.
    pub const MBUTTONUP: u32 = 0x0208;
    /// WM_MOUSEWHEEL.
    pub const MOUSEWHEEL: u32 = 0x020A;
    /// WM_XBUTTONDOWN.
    pub const XBUTTONDOWN: u32 = 0x020B;
    /// WM_XBUTTONUP.
    pub const XBUTTONUP: u32 = 0x020C;
    /// WM_MOUSEHWHEEL.
    pub const MOUSEHWHEEL: u32 = 0x020E;
    /// WM_ENTERSIZEMOVE.
    pub const ENTERSIZEMOVE: u32 = 0x0231;
    /// WM_EXITSIZEMOVE.
    pub const EXITSIZEMOVE: u32 = 0x0232;
    /// WM_NCMOUSELEAVE.
    pub const NCMOUSELEAVE: u32 = 0x02A2;
    /// WM_MOUSELEAVE.
    pub const MOUSELEAVE: u32 = 0x02A3;
    /// WM_DPICHANGED.
    pub const DPICHANGED: u32 = 0x02E0;
    /// WM_APP: the first private message.
    pub const APP: u32 = 0x8000;
};

/// Window styles.
pub const WS = struct {
    /// WS_OVERLAPPEDWINDOW.
    pub const OVERLAPPEDWINDOW: u32 = 0x00CF0000;
    /// WS_CLIPCHILDREN.
    pub const CLIPCHILDREN: u32 = 0x02000000;
    /// WS_EX_APPWINDOW.
    pub const EX_APPWINDOW: u32 = 0x00040000;
    /// WS_EX_TOPMOST.
    pub const EX_TOPMOST: u32 = 0x00000008;
};

/// `HWND_TOPMOST`: the `SetWindowPos` z-order target that keeps a
/// window above others.
pub const HWND_TOPMOST: isize = -1;
/// `HWND_NOTOPMOST`: the target that ends always-on-top.
pub const HWND_NOTOPMOST: isize = -2;

/// `CW_USEDEFAULT`.
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
/// `HWND_MESSAGE`, the parent of message-only windows.
pub const HWND_MESSAGE: isize = -3;
/// `GWLP_USERDATA`.
pub const GWLP_USERDATA: i32 = -21;
/// `PM_NOREMOVE`.
pub const PM_NOREMOVE: u32 = 0x0000;
/// `MAPVK_VK_TO_VSC_EX`.
pub const MAPVK_VK_TO_VSC_EX: u32 = 4;
/// `ToUnicodeEx` flag: leave the kernel's dead-key state alone (1607+).
pub const TOUNICODE_NO_STATE_CHANGE: u32 = 0x4;
/// `PM_REMOVE`.
pub const PM_REMOVE: u32 = 0x0001;
/// `QS_ALLINPUT`.
pub const QS_ALLINPUT: u32 = 0x04FF;
/// `MWMO_INPUTAVAILABLE`.
pub const MWMO_INPUTAVAILABLE: u32 = 0x0004;
/// `WAIT_TIMEOUT`.
pub const WAIT_TIMEOUT: u32 = 258;
/// `INFINITE`.
pub const INFINITE: u32 = 0xFFFF_FFFF;
/// `MDT_EFFECTIVE_DPI` for `GetDpiForMonitor`.
pub const MDT_EFFECTIVE_DPI: u32 = 0;
/// `LOAD_LIBRARY_SEARCH_SYSTEM32`.
pub const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x0000_0800;
/// The `WM_TIMER` id that keeps frames flowing inside the modal size/move
/// loop.
pub const modal_timer_id: usize = 0x7a67;
/// `USER_TIMER_MINIMUM` (ms).
pub const USER_TIMER_MINIMUM: u32 = 0x0A;

/// `WM_SETTINGCHANGE` (broadcast to top-level windows only).
pub const WM_SETTINGCHANGE: u32 = 0x001A;
/// `SW_SHOWNORMAL`.
pub const SW_SHOWNORMAL: i32 = 1;
/// `SW_SHOWMINIMIZED`.
pub const SW_SHOWMINIMIZED: i32 = 2;
/// `SW_MAXIMIZE`.
pub const SW_MAXIMIZE: i32 = 3;
/// `SW_RESTORE`.
pub const SW_RESTORE: i32 = 9;
/// `FLASHW_ALL`: flash the caption and the taskbar button.
pub const FLASHW_ALL: u32 = 0x3;
/// `FLASHW_TIMERNOFG`: until the window comes to the foreground.
pub const FLASHW_TIMERNOFG: u32 = 0xC;
/// `FLASHW_TRAY`: the taskbar button only.
pub const FLASHW_TRAY: u32 = 0x2;
/// `SIZE_MINIMIZED` (WM_SIZE wParam).
pub const SIZE_MINIMIZED: usize = 1;
/// `SIZE_MAXIMIZED` (WM_SIZE wParam).
pub const SIZE_MAXIMIZED: usize = 2;
/// `SWP_NOSIZE`.
pub const SWP_NOSIZE: u32 = 0x0001;
/// `SWP_NOMOVE`.
pub const SWP_NOMOVE: u32 = 0x0002;
/// `SWP_NOZORDER`.
pub const SWP_NOZORDER: u32 = 0x0004;
/// `SWP_NOACTIVATE`.
pub const SWP_NOACTIVATE: u32 = 0x0010;
/// `SWP_FRAMECHANGED`.
pub const SWP_FRAMECHANGED: u32 = 0x0020;
/// `TME_LEAVE`.
pub const TME_LEAVE: u32 = 0x0002;
/// `TME_NONCLIENT`.
pub const TME_NONCLIENT: u32 = 0x0010;
/// `TPM_RIGHTBUTTON`.
pub const TPM_RIGHTBUTTON: u32 = 0x0002;
/// `TPM_RETURNCMD`.
pub const TPM_RETURNCMD: u32 = 0x0100;
/// `IDC_ARROW`.
pub const IDC_ARROW: u16 = 32512;
/// `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`, as an integer.
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
/// `USER_DEFAULT_SCREEN_DPI`.
pub const default_dpi: u32 = 96;
/// `WHEEL_DELTA`.
pub const WHEEL_DELTA: i32 = 120;

/// `SRCCOPY` raster operation.
pub const SRCCOPY: u32 = 0x00CC0020;
/// `BLACKNESS` raster operation.
pub const BLACKNESS: u32 = 0x00000042;
/// `DIB_RGB_COLORS`.
pub const DIB_RGB_COLORS: u32 = 0;
/// `BI_RGB`.
pub const BI_RGB: u32 = 0;

/// The `CREATESTRUCTW` prefix: WM_NCCREATE's lParam points at it.
pub const CREATESTRUCTW_prefix = extern struct {
    /// The `lpParam` passed to `CreateWindowExW`.
    lpCreateParams: ?*anyopaque,
};

/// Virtual-key codes the backend reads.
pub const VK = struct {
    /// VK_BACK.
    pub const BACK: u16 = 0x08;
    /// VK_TAB.
    pub const TAB: u16 = 0x09;
    /// VK_RETURN.
    pub const RETURN: u16 = 0x0D;
    /// VK_SHIFT.
    pub const SHIFT: u16 = 0x10;
    /// VK_CONTROL.
    pub const CONTROL: u16 = 0x11;
    /// VK_MENU (Alt).
    pub const MENU: u16 = 0x12;
    /// VK_PAUSE.
    pub const PAUSE: u16 = 0x13;
    /// VK_CAPITAL (Caps Lock).
    pub const CAPITAL: u16 = 0x14;
    /// VK_ESCAPE.
    pub const ESCAPE: u16 = 0x1B;
    /// VK_SPACE.
    pub const SPACE: u16 = 0x20;
    /// VK_PRIOR (Page Up).
    pub const PRIOR: u16 = 0x21;
    /// VK_NEXT (Page Down).
    pub const NEXT: u16 = 0x22;
    /// VK_END.
    pub const END: u16 = 0x23;
    /// VK_HOME.
    pub const HOME: u16 = 0x24;
    /// VK_LEFT.
    pub const LEFT: u16 = 0x25;
    /// VK_UP.
    pub const UP: u16 = 0x26;
    /// VK_RIGHT.
    pub const RIGHT: u16 = 0x27;
    /// VK_DOWN.
    pub const DOWN: u16 = 0x28;
    /// VK_INSERT.
    pub const INSERT: u16 = 0x2D;
    /// VK_DELETE.
    pub const DELETE: u16 = 0x2E;
    /// VK_LWIN.
    pub const LWIN: u16 = 0x5B;
    /// VK_RWIN.
    pub const RWIN: u16 = 0x5C;
    /// VK_F1; F2..F24 follow.
    pub const F1: u16 = 0x70;
    /// VK_F10.
    pub const F10: u16 = 0x79;
    /// VK_F24.
    pub const F24: u16 = 0x87;
    /// VK_NUMLOCK.
    pub const NUMLOCK: u16 = 0x90;
    /// VK_SCROLL.
    pub const SCROLL: u16 = 0x91;
    /// VK_LCONTROL.
    pub const LCONTROL: u16 = 0xA2;
    /// VK_RCONTROL.
    pub const RCONTROL: u16 = 0xA3;
    /// VK_LMENU.
    pub const LMENU: u16 = 0xA4;
    /// VK_RMENU (right Alt, AltGr).
    pub const RMENU: u16 = 0xA5;
};
