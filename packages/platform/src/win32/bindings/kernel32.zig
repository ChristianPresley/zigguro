//! kernel32: modules, events and waits, global memory, code pages,
//! high-resolution time and Toolhelp snapshots.
//!
//! planned: E01.F02.S01.T02 (modules, events, timers), E01.F02.S04.T01
//! (global memory), E06 foreground-process lookup (Toolhelp).

const t = @import("types.zig");
const BOOL = t.BOOL;
const DWORD = t.DWORD;
const UINT = t.UINT;
const HANDLE = t.HANDLE;
const LPCWSTR = t.LPCWSTR;

/// `INFINITE` wait.
pub const INFINITE: DWORD = 0xFFFF_FFFF;
/// `WAIT_OBJECT_0`.
pub const WAIT_OBJECT_0: DWORD = 0;
/// `WAIT_TIMEOUT`.
pub const WAIT_TIMEOUT: DWORD = 258;
/// `GMEM_MOVEABLE` (clipboard data must be movable).
pub const GMEM_MOVEABLE: UINT = 0x0002;
/// `LOAD_LIBRARY_SEARCH_SYSTEM32`.
pub const LOAD_LIBRARY_SEARCH_SYSTEM32: DWORD = 0x0000_0800;
/// `CP_UTF8`.
pub const CP_UTF8: UINT = 65001;
/// `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`.
pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: DWORD = 0x0000_0002;
/// `TH32CS_SNAPPROCESS`.
pub const TH32CS_SNAPPROCESS: DWORD = 0x0000_0002;
/// `TIMER_ALL_ACCESS`.
pub const TIMER_ALL_ACCESS: DWORD = 0x001F_0003;

/// A loaded module's handle (null: the executable).
pub extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(.winapi) ?t.HMODULE;
/// Loads a DLL.
pub extern "kernel32" fn LoadLibraryExW(LPCWSTR, file: ?HANDLE, flags: DWORD) callconv(.winapi) ?t.HMODULE;
/// An exported symbol's address.
pub extern "kernel32" fn GetProcAddress(t.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
/// Unloads a DLL.
pub extern "kernel32" fn FreeLibrary(t.HMODULE) callconv(.winapi) BOOL;
/// Creates an event.
pub extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: BOOL, initial_state: BOOL, name: ?LPCWSTR) callconv(.winapi) ?HANDLE;
/// Signals an event.
pub extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) BOOL;
/// Waits on one handle.
pub extern "kernel32" fn WaitForSingleObject(HANDLE, ms: DWORD) callconv(.winapi) DWORD;
/// Closes a kernel handle.
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
/// The calling thread's last error code.
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
/// Suspends the calling thread.
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
/// The calling thread's id.
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
/// Allocates global memory.
pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?t.HGLOBAL;
/// Locks global memory and returns its address.
pub extern "kernel32" fn GlobalLock(t.HGLOBAL) callconv(.winapi) ?*anyopaque;
/// Unlocks global memory.
pub extern "kernel32" fn GlobalUnlock(t.HGLOBAL) callconv(.winapi) BOOL;
/// Frees global memory (null on success).
pub extern "kernel32" fn GlobalFree(t.HGLOBAL) callconv(.winapi) ?t.HGLOBAL;
/// The size of a global memory block.
pub extern "kernel32" fn GlobalSize(t.HGLOBAL) callconv(.winapi) usize;
/// Converts code-page text to UTF-16.
pub extern "kernel32" fn MultiByteToWideChar(cp: UINT, flags: DWORD, src: [*]const u8, src_len: i32, dst: ?[*]u16, dst_len: i32) callconv(.winapi) i32;
/// Converts UTF-16 to code-page text.
pub extern "kernel32" fn WideCharToMultiByte(cp: UINT, flags: DWORD, src: [*]const u16, src_len: i32, dst: ?[*]u8, dst_len: i32, default: ?[*:0]const u8, used_default: ?*BOOL) callconv(.winapi) i32;
/// The performance counter.
pub extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) BOOL;
/// The performance counter frequency.
pub extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) BOOL;
/// Creates a (high-resolution) waitable timer.
pub extern "kernel32" fn CreateWaitableTimerExW(attrs: ?*anyopaque, name: ?LPCWSTR, flags: DWORD, access: DWORD) callconv(.winapi) ?HANDLE;
/// Arms a waitable timer (due time in 100 ns units, negative = relative).
pub extern "kernel32" fn SetWaitableTimer(HANDLE, due: *const i64, period_ms: i32, completion: ?*const anyopaque, arg: ?*anyopaque, resume_system: BOOL) callconv(.winapi) BOOL;
/// Snapshots processes.
pub extern "kernel32" fn CreateToolhelp32Snapshot(flags: DWORD, pid: DWORD) callconv(.winapi) HANDLE;
/// The first process in a snapshot.
pub extern "kernel32" fn Process32FirstW(HANDLE, *t.PROCESSENTRY32W) callconv(.winapi) BOOL;
/// The next process in a snapshot.
pub extern "kernel32" fn Process32NextW(HANDLE, *t.PROCESSENTRY32W) callconv(.winapi) BOOL;
