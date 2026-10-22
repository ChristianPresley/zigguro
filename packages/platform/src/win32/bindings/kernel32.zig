//! kernel32: modules, events and waits, global memory, code pages,
//! high-resolution time, Toolhelp snapshots, and processes, pipes, job
//! objects and pseudoconsoles (ConPTY).
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

/// `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`.
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x0002_0016;
/// `EXTENDED_STARTUPINFO_PRESENT`.
pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x0008_0000;
/// `CREATE_UNICODE_ENVIRONMENT`.
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x0000_0400;
/// `CREATE_SUSPENDED`.
pub const CREATE_SUSPENDED: DWORD = 0x0000_0004;
/// `STARTF_USESTDHANDLES`: the child takes `hStd*` from STARTUPINFO (null
/// here), so it does not inherit the parent's console or stdio.
pub const STARTF_USESTDHANDLES: DWORD = 0x0000_0100;
/// `JobObjectExtendedLimitInformation`.
pub const JobObjectExtendedLimitInformation: i32 = 9;
/// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x0000_2000;
/// `STILL_ACTIVE` (`GetExitCodeProcess` of a running process).
pub const STILL_ACTIVE: DWORD = 259;
/// `ERROR_FILE_NOT_FOUND`.
pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
/// `ERROR_PATH_NOT_FOUND`.
pub const ERROR_PATH_NOT_FOUND: DWORD = 3;
/// `ERROR_ACCESS_DENIED`.
pub const ERROR_ACCESS_DENIED: DWORD = 5;
/// `ERROR_DIRECTORY`.
pub const ERROR_DIRECTORY: DWORD = 267;
/// `ERROR_BAD_EXE_FORMAT`.
pub const ERROR_BAD_EXE_FORMAT: DWORD = 193;

/// Creates an anonymous (synchronous) pipe.
pub extern "kernel32" fn CreatePipe(read: *?HANDLE, write: *?HANDLE, attrs: ?*const t.SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) BOOL;
/// Creates a pseudoconsole on two pipes (Windows 10 1809+).
pub extern "kernel32" fn CreatePseudoConsole(size: t.COORD, input: HANDLE, output: HANDLE, flags: DWORD, hpc: *?t.HPCON) callconv(.winapi) t.HRESULT;
/// Resizes a pseudoconsole.
pub extern "kernel32" fn ResizePseudoConsole(t.HPCON, size: t.COORD) callconv(.winapi) t.HRESULT;
/// Closes a pseudoconsole; its client processes lose their console.
pub extern "kernel32" fn ClosePseudoConsole(t.HPCON) callconv(.winapi) void;
/// Sizes or initializes a process attribute list.
pub extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
/// Sets one process attribute.
pub extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: DWORD, attr: usize, value: ?*const anyopaque, size: usize, prev: ?*anyopaque, ret_size: ?*usize) callconv(.winapi) BOOL;
/// Frees an attribute list's contents.
pub extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
/// Starts a process.
pub extern "kernel32" fn CreateProcessW(app: ?LPCWSTR, cmdline: ?[*:0]u16, proc_attrs: ?*const t.SECURITY_ATTRIBUTES, thread_attrs: ?*const t.SECURITY_ATTRIBUTES, inherit: BOOL, flags: DWORD, env: ?*const anyopaque, cwd: ?LPCWSTR, si: *const t.STARTUPINFOW, pi: *t.PROCESS_INFORMATION) callconv(.winapi) BOOL;
/// Resumes a suspended thread.
pub extern "kernel32" fn ResumeThread(HANDLE) callconv(.winapi) DWORD;
/// Ends a process.
pub extern "kernel32" fn TerminateProcess(HANDLE, code: UINT) callconv(.winapi) BOOL;
/// A process's exit code, or `STILL_ACTIVE`.
pub extern "kernel32" fn GetExitCodeProcess(HANDLE, code: *DWORD) callconv(.winapi) BOOL;
/// Creates a job object.
pub extern "kernel32" fn CreateJobObjectW(attrs: ?*const t.SECURITY_ATTRIBUTES, name: ?LPCWSTR) callconv(.winapi) ?HANDLE;
/// Sets job limits.
pub extern "kernel32" fn SetInformationJobObject(HANDLE, class: i32, info: *const anyopaque, size: DWORD) callconv(.winapi) BOOL;
/// Puts a process in a job.
pub extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) BOOL;
/// Ends every process in a job.
pub extern "kernel32" fn TerminateJobObject(HANDLE, code: UINT) callconv(.winapi) BOOL;
/// Reads from a file or pipe.
pub extern "kernel32" fn ReadFile(HANDLE, buf: [*]u8, len: DWORD, read: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
/// Writes to a file or pipe.
pub extern "kernel32" fn WriteFile(HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
