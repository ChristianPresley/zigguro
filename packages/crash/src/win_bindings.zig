//! kernel32/ntdll declarations for Windows crash capture
//! (E17.F05.S01.T03). windows.zig calls Win32 only through this file, so
//! the "crash path: syscall allowlist" test can check every `win.*` call
//! a `cp_*` function makes against `crash_path_calls`.

const std = @import("std");
const windows = std.os.windows;

pub const BOOL = windows.BOOL;
pub const HANDLE = windows.HANDLE;
pub const EXCEPTION_POINTERS = windows.EXCEPTION_POINTERS;

/// The only functions here a `cp_*` function may call. None takes the
/// process heap lock: file writes, events, ids, clocks, the thread list
/// into a caller buffer and the unwinder.
pub const crash_path_calls = [_][]const u8{
    "CreateFileW",        "WriteFile",               "FlushFileBuffers",         "NtClose",
    "GetCurrentThreadId", "GetCurrentProcessId",     "GetCurrentProcess",        "TerminateProcess",
    "GetTickCount64",     "GetSystemTimeAsFileTime", "SwitchToThread",           "GetStdHandle",
    "SetEvent",           "WaitForSingleObject",     "NtQuerySystemInformation", "RtlLookupFunctionEntry",
    "RtlVirtualUnwind",
};

pub const EXCEPTION_CONTINUE_SEARCH: c_long = 0;
pub const EXCEPTION_EXECUTE_HANDLER: c_long = 1;

pub const SEM_FAILCRITICALERRORS: u32 = 0x0001;
pub const SEM_NOGPFAULTERRORBOX: u32 = 0x0002;

pub const GENERIC_WRITE: u32 = 0x4000_0000;
pub const CREATE_NEW: u32 = 1;
pub const CREATE_ALWAYS: u32 = 2;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
pub const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
pub const WAIT_OBJECT_0: u32 = 0;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;

pub const FILETIME = extern struct { lo: u32, hi: u32 };

pub const TopLevelFilter = *const fn (*EXCEPTION_POINTERS) callconv(.winapi) c_long;
pub const ThreadStart = *const fn (?*anyopaque) callconv(.winapi) u32;

pub extern "kernel32" fn SetUnhandledExceptionFilter(filter: ?TopLevelFilter) callconv(.winapi) ?TopLevelFilter;
pub extern "kernel32" fn AddVectoredExceptionHandler(first: u32, handler: windows.VECTORED_EXCEPTION_HANDLER) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn SetThreadStackGuarantee(size: *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetErrorMode(mode: u32) callconv(.winapi) u32;
pub extern "kernel32" fn CreateThread(attrs: ?*anyopaque, stack: usize, start: ThreadStart, param: ?*anyopaque, flags: u32, tid: ?*u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
pub extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, attrs: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, attrs: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn FlushFileBuffers(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn GetSystemTimeAsFileTime(ft: *FILETIME) callconv(.winapi) void;
pub extern "kernel32" fn SwitchToThread() callconv(.winapi) BOOL;
pub extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?HANDLE;

pub const NtClose = windows.ntdll.NtClose;
pub const GetCurrentThreadId = windows.GetCurrentThreadId;
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const GetCurrentProcess = windows.GetCurrentProcess;
pub const NtQuerySystemInformation = windows.ntdll.NtQuerySystemInformation;
pub const RtlLookupFunctionEntry = windows.ntdll.RtlLookupFunctionEntry;
pub const RtlVirtualUnwind = windows.ntdll.RtlVirtualUnwind;
pub const RtlGetVersion = windows.ntdll.RtlGetVersion;

/// `SystemProcessInformation` records (64-bit layout): the process entry
/// is 0x100 bytes, followed by `NumberOfThreads` 0x50-byte thread entries.
pub const spi = struct {
    pub const next_entry = 0x00;
    pub const n_threads = 0x04;
    pub const pid = 0x50;
    pub const size = 0x100;
    pub const thread_size = 0x50;
    pub const thread_tid = 0x30;
};

/// NTSTATUS codes the handlers classify.
pub const status = struct {
    pub const access_violation: u32 = 0xC000_0005;
    pub const in_page_error: u32 = 0xC000_0006;
    pub const illegal_instruction: u32 = 0xC000_001D;
    pub const privileged_instruction: u32 = 0xC000_0096;
    pub const int_divide_by_zero: u32 = 0xC000_0094;
    pub const int_overflow: u32 = 0xC000_0095;
    pub const flt_divide_by_zero: u32 = 0xC000_008E;
    pub const stack_overflow: u32 = 0xC000_00FD;
    pub const breakpoint: u32 = 0x8000_0003;
    pub const datatype_misalignment: u32 = 0x8000_0002;
    pub const stack_buffer_overrun: u32 = 0xC000_0409;
    pub const info_length_mismatch: u32 = 0xC000_0004;
};
