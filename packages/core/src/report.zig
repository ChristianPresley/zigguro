//! Error reporting: the `Diagnostics` out-parameter convention and the
//! panic/crash hook used by apps (E17 installs the crash-dump writer).
//!
//! Convention (ADR 0005): a function that can fail with user-facing detail
//! takes `diag: ?*Diagnostics` and still returns a specific error set; the
//! diagnostics carry the human-readable explanation.
//!
//! Apps declare:
//! ```zig
//! pub const panic = std.debug.FullPanic(zg_core.report.panicHandler);
//! ```

const std = @import("std");

/// Accumulates user-facing messages. `add` never fails: on OOM the message
/// is dropped and counted in `dropped`.
pub const Diagnostics = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayList(Message) = .empty,
    /// Messages lost to allocation failure.
    dropped: u32 = 0,

    /// Message severity.
    pub const Severity = enum { err, warn, note };

    /// One diagnostic. `text` and `code` are owned by the Diagnostics.
    pub const Message = struct {
        severity: Severity,
        code: ?[]const u8 = null,
        text: []const u8,
        /// Byte offset into the input the message refers to, if any.
        offset: ?u64 = null,
    };

    /// An empty set using `gpa` for message storage.
    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .gpa = gpa };
    }

    /// Formats and appends a message.
    pub fn add(d: *Diagnostics, sev: Severity, comptime fmt: []const u8, args: anytype) void {
        d.addDetailed(sev, null, null, fmt, args);
    }

    /// Appends a message with an optional error code and input offset.
    pub fn addDetailed(d: *Diagnostics, sev: Severity, code: ?[]const u8, offset: ?u64, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(d.gpa, fmt, args) catch {
            d.dropped += 1;
            return;
        };
        const code_copy: ?[]const u8 = if (code) |c| d.gpa.dupe(u8, c) catch {
            d.gpa.free(text);
            d.dropped += 1;
            return;
        } else null;
        d.messages.append(d.gpa, .{ .severity = sev, .code = code_copy, .text = text, .offset = offset }) catch {
            d.gpa.free(text);
            if (code_copy) |c| d.gpa.free(c);
            d.dropped += 1;
        };
    }

    /// True if any `.err` message was recorded (or dropped).
    pub fn hasErrors(d: *const Diagnostics) bool {
        for (d.messages.items) |m| if (m.severity == .err) return true;
        return d.dropped != 0;
    }

    /// Frees every message.
    pub fn deinit(d: *Diagnostics) void {
        for (d.messages.items) |m| {
            d.gpa.free(m.text);
            if (m.code) |c| d.gpa.free(c);
        }
        d.messages.deinit(d.gpa);
        d.* = undefined;
    }
};

/// Called once on the first panic with the message and the first trace
/// address; must not allocate or panic. E17 writes the crash dump here.
pub const CrashHook = *const fn (msg: []const u8, ret_addr: ?usize) void;

var crash_hook: ?CrashHook = null;
var crashing: std.atomic.Value(bool) = .init(false);

/// Installs the crash hook (replaces any previous one).
pub fn setCrashHook(h: ?CrashHook) void {
    crash_hook = h;
}

/// Runs the crash hook at most once per process; returns whether it ran.
/// Recursive or concurrent panics skip the hook.
pub fn invokeCrashHook(msg: []const u8, ret_addr: ?usize) bool {
    if (crashing.swap(true, .acq_rel)) return false;
    const h = crash_hook orelse return false;
    h(msg, ret_addr);
    return true;
}

/// Panic handler for `std.debug.FullPanic`: runs the crash hook once, then
/// the default panic (stack trace and abort).
pub fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = invokeCrashHook(msg, first_trace_addr);
    std.debug.defaultPanic(msg, first_trace_addr);
}

test "report: Diagnostics accumulates and never fails on OOM" {
    var d = Diagnostics.init(std.testing.allocator);
    defer d.deinit();
    d.add(.warn, "unused {s}", .{"x"});
    d.addDetailed(.err, "E001", 12, "bad token {d}", .{7});
    try std.testing.expectEqual(@as(usize, 2), d.messages.items.len);
    try std.testing.expectEqualStrings("bad token 7", d.messages.items[1].text);
    try std.testing.expect(d.hasErrors());

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var f = Diagnostics.init(failing.allocator());
    defer f.deinit();
    f.add(.err, "will be dropped", .{});
    try std.testing.expectEqual(@as(u32, 1), f.dropped);
    try std.testing.expect(f.hasErrors());
}

test "report: crash hook invoked once" {
    const Hook = struct {
        var calls: u32 = 0;
        fn h(msg: []const u8, _: ?usize) void {
            std.debug.assert(std.mem.eql(u8, msg, "boom"));
            calls += 1;
        }
    };
    setCrashHook(Hook.h);
    defer setCrashHook(null);
    try std.testing.expect(invokeCrashHook("boom", null));
    try std.testing.expect(!invokeCrashHook("boom", null));
    try std.testing.expectEqual(@as(u32, 1), Hook.calls);
    crashing.store(false, .release);
}
