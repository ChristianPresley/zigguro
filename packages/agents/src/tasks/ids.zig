//! Task ids (E13.F03.S01.T01): `T-` and a counter of at least four
//! digits (`T-0042`). The next id is one more than the largest seen,
//! remembered in `.zigguro/state/tasks.zon` so deleted ids are not
//! reused. File names are `T-0042-<slug>.md`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const TaskId = u32;

pub const state_file = "tasks.zon";

/// `T-0042`, `t-42` or `42`.
pub fn parse(s: []const u8) ?TaskId {
    var t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and (t[0] == 'T' or t[0] == 't') and t[1] == '-') t = t[2..];
    if (t.len == 0 or t.len > 9) return null;
    const v = std.fmt.parseInt(TaskId, t, 10) catch return null;
    return if (v == 0) null else v;
}

pub const Formatted = struct {
    buf: [16]u8,
    len: u8,

    pub fn slice(f: *const Formatted) []const u8 {
        return f.buf[0..f.len];
    }
};

pub fn format(id: TaskId) Formatted {
    var f: Formatted = .{ .buf = undefined, .len = 0 };
    f.len = @intCast((std.fmt.bufPrint(&f.buf, "T-{d:0>4}", .{id}) catch unreachable).len);
    return f;
}

/// Lowercase ASCII words joined by `-`, at most 48 bytes.
pub fn slug(out: []u8, title: []const u8) []const u8 {
    var n: usize = 0;
    var dash = false;
    for (title) |c| {
        if (n >= out.len or n >= 48) break;
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and n > 0) {
                out[n] = '-';
                n += 1;
                if (n >= out.len) break;
            }
            dash = false;
            out[n] = std.ascii.toLower(c);
            n += 1;
        } else dash = true;
    }
    return std.mem.trimEnd(u8, out[0..n], "-");
}

/// `T-0042-fix-the-login-bug.md`.
pub fn fileName(a: Allocator, id: TaskId, title: []const u8) Allocator.Error![]u8 {
    var sb: [64]u8 = undefined;
    const s = slug(&sb, title);
    const f = format(id);
    if (s.len == 0) return std.fmt.allocPrint(a, "{s}.md", .{f.slice()});
    return std.fmt.allocPrint(a, "{s}-{s}.md", .{ f.slice(), s });
}

/// A title for a file without one: its name without the id and `.md`,
/// dashes as spaces is left to the UI.
pub fn titleFromPath(path: []const u8) []const u8 {
    var p = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, p, ".md")) p = p[0 .. p.len - 3];
    return p;
}

const State = struct { version: u32 = 1, next: TaskId = 1 };

/// The persisted counter (1 when absent or unreadable).
pub fn loadNext(io: Io, dir: Io.Dir) TaskId {
    var buf: [256]u8 = undefined;
    const bytes = dir.readFile(io, state_file, &buf) catch return 1;
    var scratch: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&scratch);
    const z = fba.allocator().dupeZ(u8, bytes) catch return 1;
    const s = std.zon.parse.fromSliceAlloc(State, fba.allocator(), z, null, .{ .ignore_unknown_fields = true }) catch return 1;
    return @max(s.next, 1);
}

pub fn saveNext(io: Io, dir: Io.Dir, next: TaskId) !void {
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, ".{{ .version = 1, .next = {d} }}\n", .{next});
    var af = try dir.createFileAtomic(io, state_file, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, text);
    try af.replace(io);
}

test "ids" {
    const t = std.testing;
    try t.expectEqual(@as(?TaskId, 42), parse("T-0042"));
    try t.expectEqual(@as(?TaskId, 42), parse("t-42"));
    try t.expectEqual(@as(?TaskId, 7), parse("7"));
    try t.expectEqual(@as(?TaskId, 12345), parse("T-12345"));
    try t.expect(parse("T-") == null);
    try t.expect(parse("T-0") == null);
    try t.expect(parse("X-1") == null);
    try t.expectEqualStrings("T-0042", format(42).slice());
    try t.expectEqualStrings("T-12345", format(12345).slice());
    var sb: [64]u8 = undefined;
    try t.expectEqualStrings("fix-the-login-bug", slug(&sb, "  Fix the login bug!! "));
    try t.expectEqualStrings("", slug(&sb, "???"));
    const n = try fileName(t.allocator, 1, "Write docs: tasks.md");
    defer t.allocator.free(n);
    try t.expectEqualStrings("T-0001-write-docs-tasks-md.md", n);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try t.expectEqual(@as(TaskId, 1), loadNext(t.io, tmp.dir));
    try saveNext(t.io, tmp.dir, 17);
    try t.expectEqual(@as(TaskId, 17), loadNext(t.io, tmp.dir));
}
