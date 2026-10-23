//! Trigger guards (E13.F02.S02.T01): paths no trigger may see, the
//! provenance runs attach to their writes, and the self-trigger and
//! chain rules built on it. Pure.

const std = @import("std");
const runs = @import("../runs/root.zig");

/// Who caused an event: attached by E12 (changesets) and E09 (lanes) to
/// changes an E13 run applied.
pub const Provenance = struct {
    run: ?runs.RunId = null,
    /// The automation the run belongs to.
    automation: ?[]const u8 = null,
    /// The run's own chain depth.
    depth: u8 = 0,
};

/// The scheduler's own files, run outputs and repositories never trigger.
pub const internal_dirs = [_][]const u8{ ".zigguro/runs/", ".zigguro/state/", ".git/", ".zg/" };

pub fn isInternal(rel_path: []const u8) bool {
    for (internal_dirs) |d| {
        if (std.mem.startsWith(u8, rel_path, d)) return true;
        if (std.mem.eql(u8, rel_path, d[0 .. d.len - 1])) return true;
    }
    return false;
}

/// Workspace-relative with `/` separators and no leading `./` or `/`
/// (Windows paths arrive with `\`). Returns a slice of `buf`, or null
/// when the path does not fit.
pub fn normalize(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len > buf.len) return null;
    for (path, 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
    var p: []const u8 = buf[0..path.len];
    while (true) {
        if (std.mem.startsWith(u8, p, "./")) {
            p = p[2..];
        } else if (p.len > 0 and p[0] == '/') {
            p = p[1..];
        } else break;
    }
    return p;
}

/// An event caused by the automation's own run.
pub fn isSelf(p: ?Provenance, automation: []const u8) bool {
    const v = p orelse return false;
    const a = v.automation orelse return false;
    return std.mem.eql(u8, a, automation);
}

/// The chain depth of a fire caused by an event: one more than the run
/// that caused it, 0 for events from people and tools.
pub fn depthFor(p: ?Provenance) u8 {
    const v = p orelse return 0;
    if (v.automation == null and v.run == null) return 0;
    return v.depth +| 1;
}

test "guards" {
    const t = std.testing;
    try t.expect(isInternal(".zigguro/runs/automations/x.jsonl"));
    try t.expect(isInternal(".git/index"));
    try t.expect(isInternal(".zg"));
    try t.expect(!isInternal(".zigguro/automations/x.zon"));
    try t.expect(!isInternal("src/.git-keep"));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("src/a.zig", normalize(".\\src\\a.zig", &buf).?);
    try t.expectEqualStrings("a", normalize("/a", &buf).?);
    try t.expect(isSelf(.{ .automation = "tidy" }, "tidy"));
    try t.expect(!isSelf(.{ .automation = "other" }, "tidy"));
    try t.expect(!isSelf(null, "tidy"));
    try t.expectEqual(@as(u8, 0), depthFor(null));
    try t.expectEqual(@as(u8, 3), depthFor(.{ .automation = "a", .depth = 2 }));
}
