//! The exception a stop broke on (E07.F07.S01.T04): after a `stopped`
//! event with `reason: exception`, `exceptionInfo { threadId }` when the
//! adapter supports it (`supportsExceptionInfoRequest`), else the stop's
//! own description and text. A `signal` stop (GDB's for SIGSEGV and the
//! like) is one too, from the stop alone. The editor shows it under the line the
//! thread stopped at; it goes on the next continue.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Exception = struct {
    arena: std.heap.ArenaAllocator,
    thread: i64,
    /// `exceptionId` (or the stop's description), e.g. "SIGSEGV".
    id: []const u8,
    description: ?[]const u8 = null,
    /// `never`, `always`, `unhandled` or `userUnhandled` ("" unknown).
    break_mode: []const u8 = "",
    /// From `details`, when given.
    type_name: ?[]const u8 = null,
    message: ?[]const u8 = null,
    stack_trace: ?[]const u8 = null,
    /// Inner exceptions' messages (or type names), outermost first.
    inner: []const []const u8 = &.{},
    /// A signal, not an exception.
    signal: bool = false,

    pub fn deinit(e: *Exception) void {
        e.arena.deinit();
        e.* = undefined;
    }

    /// The headline: the type name or id.
    pub fn title(e: *const Exception) []const u8 {
        if (e.type_name) |t| if (t.len > 0) return t;
        return e.id;
    }
};

const Details = struct {
    message: ?[]const u8 = null,
    typeName: ?[]const u8 = null,
    fullTypeName: ?[]const u8 = null,
    stackTrace: ?[]const u8 = null,
    innerException: ?[]const std.json.Value = null,
};

/// An `exceptionInfo` response body.
pub fn parse(gpa: Allocator, thread: i64, body: []const u8) !Exception {
    var e: Exception = .{ .arena = .init(gpa), .thread = thread, .id = "" };
    errdefer e.arena.deinit();
    const a = e.arena.allocator();
    const B = struct {
        exceptionId: []const u8 = "",
        description: ?[]const u8 = null,
        breakMode: []const u8 = "",
        details: ?Details = null,
    };
    const b = std.json.parseFromSliceLeaky(B, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidBody,
    };
    e.id = b.exceptionId;
    e.description = b.description;
    e.break_mode = b.breakMode;
    if (b.details) |d| {
        e.type_name = d.typeName orelse d.fullTypeName;
        e.message = d.message;
        e.stack_trace = d.stackTrace;
        var inner: std.ArrayList([]const u8) = .empty;
        var next = d.innerException;
        // Each level's first inner exception, a few deep.
        var depth: u8 = 0;
        while (next) |list| : (depth += 1) {
            if (list.len == 0 or depth >= 8) break;
            const x = std.json.parseFromValueLeaky(Details, a, list[0], .{ .ignore_unknown_fields = true }) catch break;
            if (x.message orelse x.typeName) |m| try inner.append(a, m);
            next = x.innerException;
        }
        e.inner = inner.items;
    }
    if (e.id.len == 0) e.id = e.description orelse "exception";
    return e;
}

/// From the stop alone (an adapter without `exceptionInfo`, a signal).
pub fn fromStop(gpa: Allocator, thread: i64, description: ?[]const u8, text: ?[]const u8, signal: bool) Allocator.Error!Exception {
    var e: Exception = .{ .arena = .init(gpa), .thread = thread, .id = if (signal) "signal" else "exception", .signal = signal };
    errdefer e.arena.deinit();
    const a = e.arena.allocator();
    if (description) |d| e.id = try a.dupe(u8, d);
    if (text) |t| e.message = try a.dupe(u8, t);
    return e;
}

test "exception: exceptionInfo body with details and inner exceptions" {
    const testing = std.testing;
    var e = try parse(testing.allocator, 3,
        \\{"exceptionId":"System.InvalidOperationException","description":"Sequence contains no elements","breakMode":"unhandled",
        \\ "details":{"message":"Sequence contains no elements","typeName":"InvalidOperationException","stackTrace":"at A()\nat B()",
        \\  "innerException":[{"message":"inner one","innerException":[{"typeName":"Deeper"}]}]}}
    );
    defer e.deinit();
    try testing.expectEqual(@as(i64, 3), e.thread);
    try testing.expectEqualStrings("InvalidOperationException", e.title());
    try testing.expectEqualStrings("unhandled", e.break_mode);
    try testing.expectEqualStrings("at A()\nat B()", e.stack_trace.?);
    try testing.expectEqual(@as(usize, 2), e.inner.len);
    try testing.expectEqualStrings("inner one", e.inner[0]);
    try testing.expectEqualStrings("Deeper", e.inner[1]);

    var f = try parse(testing.allocator, 1, "{\"exceptionId\":\"SIGSEGV\",\"breakMode\":\"always\"}");
    defer f.deinit();
    try testing.expectEqualStrings("SIGSEGV", f.title());
    try testing.expect(f.message == null);
    try testing.expectError(error.InvalidBody, parse(testing.allocator, 1, "[1]"));

    var g = try fromStop(testing.allocator, 1, "Segmentation fault", "at 0x0", true);
    defer g.deinit();
    try testing.expectEqualStrings("Segmentation fault", g.title());
    try testing.expectEqualStrings("at 0x0", g.message.?);
    try testing.expect(g.signal);
}
