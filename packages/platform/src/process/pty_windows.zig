//! `Pty` on Windows: ConPTY (Windows 10 1809+). The child runs suspended
//! inside a kill-on-close job object until it is assigned, so its whole
//! tree dies with the PTY even if zigguro crashes. ConPTY's pipes are
//! synchronous, so a reader thread blocks in `ReadFile` and fills a 1 MiB
//! ring that `read` drains without blocking; a full ring makes the reader
//! wait (output is never dropped). Writes go straight to the input pipe.

const std = @import("std");
const pty = @import("pty.zig");
const cmdline = @import("cmdline_windows.zig");
const t = @import("../win32/bindings/types.zig");
const k32 = @import("../win32/bindings/kernel32.zig");

const ring_size = 1 << 20;

/// Output read by the reader thread and drained by `read`.
const Ring = struct {
    mutex: std.Io.Mutex = .init,
    buf: []u8,
    head: usize = 0,
    len: usize = 0,
    eof: bool = false,
    /// Closing: drop output so `ClosePseudoConsole` (which can wait for
    /// its final output to be read) never waits on a full ring.
    discard: bool = false,
    /// Auto-reset: bytes arrived or EOF.
    data: t.HANDLE,
    /// Auto-reset: `read` made room.
    space: t.HANDLE,
};

/// The Windows PTY state behind `pty.Pty`.
pub const WindowsPty = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    hpc: ?t.HPCON,
    /// Our ends of the pipes.
    in_write: ?t.HANDLE,
    out_read: ?t.HANDLE,
    process: t.HANDLE,
    job: t.HANDLE,
    ring: *Ring,
    reader: ?std.Thread = null,
    spawned_ns: u64,
    status: ?pty.ExitStatus = null,

    /// Creates the pseudoconsole and starts `opts.argv` on it.
    pub fn spawn(gpa: std.mem.Allocator, io: std.Io, opts: pty.SpawnOptions) pty.Error!WindowsPty {
        if (opts.argv.len == 0) return error.EmptyArgv;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        if (opts.policy) |p| if (p.wrapper_argv) |w| try argv.appendSlice(gpa, w);
        try argv.appendSlice(gpa, opts.argv);
        const line = cmdline.commandLine(gpa, argv.items) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidExe,
        };
        defer gpa.free(line);
        const env_block = cmdline.envBlock(gpa, opts.env, opts.policy, opts.term) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unexpected,
        };
        defer gpa.free(env_block);
        const cwd: ?[:0]u16 = if (opts.cwd) |c| std.unicode.utf8ToUtf16LeAllocZ(gpa, c) catch return error.BadCwd else null;
        defer if (cwd) |c| gpa.free(c);

        // ConPTY needs synchronous pipes: it reads in_read, writes out_write.
        var in_read: ?t.HANDLE = null;
        var in_write: ?t.HANDLE = null;
        var out_read: ?t.HANDLE = null;
        var out_write: ?t.HANDLE = null;
        if (k32.CreatePipe(&in_read, &in_write, null, 0) == 0) return error.SystemResources;
        errdefer closeHandle(in_write);
        defer closeHandle(in_read);
        if (k32.CreatePipe(&out_read, &out_write, null, 0) == 0) return error.SystemResources;
        errdefer closeHandle(out_read);
        defer closeHandle(out_write);

        var hpc: ?t.HPCON = null;
        if (k32.CreatePseudoConsole(coord(opts.size), in_read.?, out_write.?, 0, &hpc) < 0) return error.SystemResources;
        errdefer k32.ClosePseudoConsole(hpc.?);

        var attr_size: usize = 0;
        _ = k32.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attrs = try gpa.alignedAlloc(u8, .of(usize), attr_size);
        defer gpa.free(attrs);
        if (k32.InitializeProcThreadAttributeList(attrs.ptr, 1, 0, &attr_size) == 0) return error.SystemResources;
        defer k32.DeleteProcThreadAttributeList(attrs.ptr);
        if (k32.UpdateProcThreadAttribute(attrs.ptr, 0, k32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc.?, @sizeOf(t.HPCON), null, null) == 0) return error.SystemResources;

        const job = k32.CreateJobObjectW(null, null) orelse return error.SystemResources;
        errdefer closeHandle(job);
        var limits: t.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{ .LimitFlags = k32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE };
        if (k32.SetInformationJobObject(job, k32.JobObjectExtendedLimitInformation, &limits, @sizeOf(t.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0) return error.SystemResources;

        var si: t.STARTUPINFOEXW = .{ .StartupInfo = .{ .cb = @sizeOf(t.STARTUPINFOEXW), .dwFlags = k32.STARTF_USESTDHANDLES }, .lpAttributeList = attrs.ptr };
        var pi: t.PROCESS_INFORMATION = .{};
        const flags = k32.EXTENDED_STARTUPINFO_PRESENT | k32.CREATE_UNICODE_ENVIRONMENT | k32.CREATE_SUSPENDED;
        if (k32.CreateProcessW(null, line.ptr, null, null, 0, flags, env_block.ptr, if (cwd) |c| c.ptr else null, &si.StartupInfo, &pi) == 0) {
            return switch (k32.GetLastError()) {
                k32.ERROR_FILE_NOT_FOUND, k32.ERROR_PATH_NOT_FOUND => error.FileNotFound,
                k32.ERROR_ACCESS_DENIED => error.AccessDenied,
                k32.ERROR_DIRECTORY => error.BadCwd,
                k32.ERROR_BAD_EXE_FORMAT => error.InvalidExe,
                else => error.Unexpected,
            };
        }
        errdefer {
            _ = k32.TerminateProcess(pi.hProcess.?, 1);
            closeHandle(pi.hProcess);
        }
        defer closeHandle(pi.hThread);
        // In the job before it runs a single instruction.
        _ = k32.AssignProcessToJobObject(job, pi.hProcess.?);
        _ = k32.ResumeThread(pi.hThread.?);

        const ring = try gpa.create(Ring);
        errdefer gpa.destroy(ring);
        const buf = try gpa.alloc(u8, ring_size);
        errdefer gpa.free(buf);
        const data = k32.CreateEventW(null, 0, 0, null) orelse return error.SystemResources;
        errdefer closeHandle(data);
        const space = k32.CreateEventW(null, 0, 0, null) orelse return error.SystemResources;
        errdefer closeHandle(space);
        ring.* = .{ .buf = buf, .data = data, .space = space };

        var self: WindowsPty = .{
            .gpa = gpa,
            .io = io,
            .hpc = hpc,
            .in_write = in_write,
            .out_read = out_read,
            .process = pi.hProcess.?,
            .job = job,
            .ring = ring,
            .spawned_ns = nowNs(io),
        };
        self.reader = std.Thread.spawn(.{}, readLoop, .{ io, out_read.?, ring }) catch return error.SystemResources;
        return self;
    }

    fn coord(size: pty.PtySize) t.COORD {
        return .{ .X = @intCast(@min(@max(size.cols, 1), 32767)), .Y = @intCast(@min(@max(size.rows, 1), 32767)) };
    }

    fn closeHandle(h: ?t.HANDLE) void {
        if (h) |x| _ = k32.CloseHandle(x);
    }

    fn nowNs(io: std.Io) u64 {
        return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    }

    /// Blocks in `ReadFile` and moves output into the ring until the
    /// pseudoconsole closes its end.
    fn readLoop(io: std.Io, out: t.HANDLE, ring: *Ring) void {
        var chunk: [64 << 10]u8 = undefined;
        while (true) {
            var n: t.DWORD = 0;
            if (k32.ReadFile(out, &chunk, chunk.len, &n, null) == 0 or n == 0) break;
            var off: usize = 0;
            while (off < n) {
                ring.mutex.lockUncancelable(io);
                if (ring.discard) {
                    ring.mutex.unlock(io);
                    break;
                }
                const free = ring.buf.len - ring.len;
                const take = @min(free, n - off);
                var i: usize = 0;
                while (i < take) : (i += 1) ring.buf[(ring.head + ring.len + i) % ring.buf.len] = chunk[off + i];
                ring.len += take;
                ring.mutex.unlock(io);
                off += take;
                if (take > 0) _ = k32.SetEvent(ring.data);
                // Full: wait for `read` to make room.
                if (off < n) _ = k32.WaitForSingleObject(ring.space, 50);
            }
        }
        ring.mutex.lockUncancelable(io);
        ring.eof = true;
        ring.mutex.unlock(io);
        _ = k32.SetEvent(ring.data);
    }

    /// See `pty.Pty.read`.
    pub fn read(self: *WindowsPty, buf: []u8) pty.Error!usize {
        const r = self.ring;
        r.mutex.lockUncancelable(self.io);
        defer r.mutex.unlock(self.io);
        if (r.len == 0) return if (r.eof) 0 else error.WouldBlock;
        const n = @min(buf.len, r.len);
        for (buf[0..n], 0..) |*b, i| b.* = r.buf[(r.head + i) % r.buf.len];
        r.head = (r.head + n) % r.buf.len;
        r.len -= n;
        _ = k32.SetEvent(r.space);
        return n;
    }

    /// See `pty.Pty.write`.
    pub fn write(self: *WindowsPty, bytes: []const u8) pty.Error!usize {
        const h = self.in_write orelse return error.Closed;
        var n: t.DWORD = 0;
        if (k32.WriteFile(h, bytes.ptr, @intCast(@min(bytes.len, 1 << 30)), &n, null) == 0) return error.Closed;
        return n;
    }

    /// See `pty.Pty.waitReadable`.
    pub fn waitReadable(self: *WindowsPty, timeout_ns: ?u64) bool {
        if (self.readable()) return true;
        const ms: t.DWORD = if (timeout_ns) |ns| @intCast(@min(ns / std.time.ns_per_ms, k32.INFINITE - 1)) else k32.INFINITE;
        _ = k32.WaitForSingleObject(self.ring.data, ms);
        return self.readable();
    }

    fn readable(self: *WindowsPty) bool {
        const r = self.ring;
        r.mutex.lockUncancelable(self.io);
        defer r.mutex.unlock(self.io);
        return r.len > 0 or r.eof;
    }

    /// See `pty.Pty.resize`.
    pub fn resize(self: *WindowsPty, size: pty.PtySize) pty.Error!void {
        const h = self.hpc orelse return error.Closed;
        if (k32.ResizePseudoConsole(h, coord(size)) < 0) return error.SystemResources;
    }

    fn statusOf(self: *WindowsPty) ?pty.ExitStatus {
        var code: t.DWORD = 0;
        if (k32.GetExitCodeProcess(self.process, &code) == 0 or code == k32.STILL_ACTIVE) return null;
        return .{ .exited = @truncate(code) };
    }

    /// See `pty.Pty.wait`.
    pub fn wait(self: *WindowsPty) pty.Error!pty.ExitStatus {
        if (self.status) |s| return s;
        _ = k32.WaitForSingleObject(self.process, k32.INFINITE);
        self.status = self.statusOf() orelse return error.Unexpected;
        return self.status.?;
    }

    /// See `pty.Pty.tryWait`.
    pub fn tryWait(self: *WindowsPty) pty.Error!?pty.ExitStatus {
        if (self.status) |s| return s;
        if (k32.WaitForSingleObject(self.process, 0) != k32.WAIT_OBJECT_0) return null;
        self.status = self.statusOf();
        return self.status;
    }

    /// Closes the pseudoconsole: its clients lose their console and the
    /// reader sees EOF. Not within 100 ms of spawn, which can make the
    /// child fail to start (0xC0000142).
    fn closeConsole(self: *WindowsPty) void {
        const h = self.hpc orelse return;
        const age = nowNs(self.io) -| self.spawned_ns;
        if (age < 100 * std.time.ns_per_ms) self.io.sleep(.fromNanoseconds(@intCast(100 * std.time.ns_per_ms - age)), .awake) catch {};
        self.hpc = null;
        k32.ClosePseudoConsole(h);
    }

    /// See `pty.Pty.kill`.
    pub fn kill(self: *WindowsPty, how: pty.KillMode) void {
        switch (how) {
            .hangup => self.closeConsole(),
            .terminate => _ = k32.TerminateProcess(self.process, 1),
            .kill_tree => _ = k32.TerminateJobObject(self.job, 1),
        }
    }

    /// See `pty.Pty.close`. Ends the whole tree if it is still running.
    pub fn close(self: *WindowsPty) void {
        // Our input end first, then the console: the reader drains the
        // final output and sees EOF.
        closeHandle(self.in_write);
        self.in_write = null;
        self.ring.mutex.lockUncancelable(self.io);
        self.ring.discard = true;
        self.ring.len = 0;
        self.ring.mutex.unlock(self.io);
        _ = k32.SetEvent(self.ring.space);
        self.closeConsole();
        if (k32.WaitForSingleObject(self.process, 2000) != k32.WAIT_OBJECT_0) _ = k32.TerminateJobObject(self.job, 1);
        if (self.reader) |th| th.join();
        closeHandle(self.out_read);
        closeHandle(self.process);
        closeHandle(self.job);
        closeHandle(self.ring.data);
        closeHandle(self.ring.space);
        self.gpa.free(self.ring.buf);
        self.gpa.destroy(self.ring);
        self.* = undefined;
    }
};
