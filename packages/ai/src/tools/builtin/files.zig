//! The file tools (`read_file`, `edit_file`, `multi_edit`, `write_file`)
//! and their seam to the workspace.
//!
//! In the IDE, `Files` is backed by E05's `AgentEditSession`: reads see
//! unsaved buffers, and proposals are rebased over the user's typing and
//! applied or turned into pending E12 changes as policy decides. zg_ai
//! cannot import zg_editor (same layer), so the app passes it in. `zg
//! agent` uses `DiskFiles`, which reads and writes files directly.

const std = @import("std");
const proto = @import("zg_ai_proto");
const deps = @import("../../loop/deps.zig");
const registry = @import("../registry.zig");
const ReadTracker = @import("../read_tracker.zig").ReadTracker;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Resolved = struct {
    /// Absolute, normalized, symlinks resolved when the file exists.
    abs: []const u8,
    /// Relative to the workspace root when inside it, else `abs`.
    rel: []const u8,
    inside_workspace: bool,
};

pub const Kind = enum { file, directory, missing };

pub const Read = struct {
    /// Changes whenever the content changes.
    version: u64,
    /// The file's bytes, or the editor buffer's text when it is open.
    bytes: []const u8,
    size: u64,
    /// Came from an unsaved editor buffer.
    from_buffer: bool = false,
};

pub const Occurrence = union(enum) { unique, all };

pub const Proposal = union(enum) {
    str_replace: struct { old: []const u8, new: []const u8, occurrence: Occurrence = .unique },
    /// Replaces the file; `base_version` is the version the agent read.
    whole_file: struct { text: []const u8, base_version: ?u64 },
    /// A new file (parents are created when it is applied).
    create: struct { text: []const u8 },
};

/// 1-based, inclusive.
pub const LineRange = struct { first: u64, last: u64 };

pub const Rejection = union(enum) {
    not_found,
    not_unique: u64,
    /// The user changed the same text since the agent's read.
    conflict: []const LineRange,
    /// The file changed since the agent read it.
    stale,
    read_only,
    too_large,
    already_exists,
    denied: []const u8,
    io: []const u8,
};

pub const Outcome = union(enum) {
    applied: struct { version: u64 },
    pending: struct { changeset: u64 },
    rejected: Rejection,
};

/// Who proposes a change (E12 groups an agent turn's changes into one
/// changeset).
pub const Origin = struct {
    agent: proto.AgentRef,
    tool: []const u8,
    tool_call_id: []const u8,
};

pub const Files = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resolve: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, path: []const u8) Allocator.Error!Resolved,
        kind: *const fn (ctx: *anyopaque, io: Io, abs: []const u8) Kind,
        /// Up to `max_bytes`; `size` is the full size.
        read: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8, max_bytes: usize) anyerror!Read,
        propose: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8, p: Proposal, origin: Origin) anyerror!Outcome,
    };

    pub fn resolve(f: Files, io: Io, arena: Allocator, path: []const u8) Allocator.Error!Resolved {
        return f.vtable.resolve(f.ctx, io, arena, path);
    }
    pub fn kind(f: Files, io: Io, abs: []const u8) Kind {
        return f.vtable.kind(f.ctx, io, abs);
    }
    pub fn read(f: Files, io: Io, arena: Allocator, abs: []const u8, max_bytes: usize) anyerror!Read {
        return f.vtable.read(f.ctx, io, arena, abs, max_bytes);
    }
    pub fn propose(f: Files, io: Io, arena: Allocator, abs: []const u8, p: Proposal, origin: Origin) anyerror!Outcome {
        return f.vtable.propose(f.ctx, io, arena, abs, p, origin);
    }
};

pub const Access = enum { read, write };

/// E16's path policy (secret files, paths outside the workspace). Null
/// allows the workspace and denies everything outside it.
pub const PathPolicy = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, io: Io, agent: proto.AgentRef, r: Resolved, access: Access) Io.Cancelable!deps.Decision,
};

pub const Config = struct {
    default_limit: u32 = 2_000,
    max_line_chars: usize = 2_000,
    /// Above this, read_file needs offset and limit.
    large_file_bytes: u64 = 50 << 20,
    max_image_bytes: u64 = 5 << 20,
    /// What the model can take as tool results.
    image_input: bool = false,
    pdf_input: bool = false,
    diff_lines: usize = 40,
};

/// The four file tools over one `Files`.
pub const FileTools = struct {
    files: Files,
    tracker: *ReadTracker,
    cfg: Config = .{},
    policy: ?PathPolicy = null,
    spec_buf: [4]proto.ToolSpec = undefined,

    pub fn specs(ft: *FileTools) []const proto.ToolSpec {
        ft.spec_buf = .{
            @import("read.zig").spec(ft),
            @import("edit.zig").editSpec(ft),
            @import("edit.zig").multiEditSpec(ft),
            @import("write.zig").spec(ft),
        };
        return &ft.spec_buf;
    }

    /// A built-in tool source with the four tools.
    pub fn source(ft: *FileTools) registry.ToolSource {
        return .{ .name = "files", .ctx = ft, .list = listSpecs, .kind = .builtin };
    }

    fn listSpecs(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const ft: *FileTools = @ptrCast(@alignCast(ctx));
        try out.appendSlice(gpa, ft.specs());
    }

    /// Resolves `path` and asks the policy; a denial is the error text.
    pub fn open(ft: *FileTools, c: *proto.ToolCall, path: []const u8, access: Access) proto.ToolError!union(enum) { ok: Resolved, denied: []const u8 } {
        const r = try ft.files.resolve(c.io, c.arena, path);
        if (ft.policy) |p| {
            switch (p.check(p.ctx, c.io, c.agent, r, access) catch return error.Canceled) {
                .allow, .allow_edited => return .{ .ok = r },
                .deny => |why| return .{ .denied = why },
            }
        }
        if (!r.inside_workspace) return .{ .denied = try std.fmt.allocPrint(c.arena, "{s} is outside the workspace", .{r.abs}) };
        return .{ .ok = r };
    }
};

/// The result of applying `str_replace` to `text`.
pub const Replaced = union(enum) {
    ok: struct { text: []const u8, count: u64, crlf_adjusted: bool = false },
    not_found,
    not_unique: u64,
};

/// Replaces `old` with `new` in `text`: exactly one match for `.unique`.
/// When `old` is not found and the text uses CRLF, retries with `old`
/// and `new` converted to CRLF.
pub fn strReplace(a: Allocator, text: []const u8, old: []const u8, new: []const u8, occ: Occurrence) Allocator.Error!Replaced {
    const r = try replaceExact(a, text, old, new, occ);
    if (r != .not_found or std.mem.indexOf(u8, text, "\r\n") == null or std.mem.indexOfScalar(u8, old, '\n') == null) return r;
    const old_crlf = try toCrlf(a, old);
    const new_crlf = try toCrlf(a, new);
    var again = try replaceExact(a, text, old_crlf, new_crlf, occ);
    if (again == .ok) again.ok.crlf_adjusted = true;
    return again;
}

fn replaceExact(a: Allocator, text: []const u8, old: []const u8, new: []const u8, occ: Occurrence) Allocator.Error!Replaced {
    if (old.len == 0) return .not_found;
    const count = std.mem.count(u8, text, old);
    if (count == 0) return .not_found;
    if (occ == .unique and count > 1) return .{ .not_unique = count };
    const out = try std.mem.replaceOwned(u8, a, text, old, new);
    return .{ .ok = .{ .text = out, .count = count } };
}

fn toCrlf(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        if (c == '\n' and (i == 0 or s[i - 1] != '\r')) try out.append(a, '\r');
        try out.append(a, c);
    }
    return out.items;
}

pub const DiffStat = struct { added: usize, removed: usize };

/// Writes a compact unified diff of `before` → `after` (one hunk around
/// the changed lines, 3 lines of context, at most `max_lines` lines) and
/// returns the line counts.
pub fn writeDiff(w: *std.Io.Writer, a: Allocator, path: []const u8, before: []const u8, after: []const u8, max_lines: usize) !DiffStat {
    const old = try splitLines(a, before);
    const new = try splitLines(a, after);
    var pre: usize = 0;
    while (pre < old.len and pre < new.len and std.mem.eql(u8, old[pre], new[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < old.len - pre and suf < new.len - pre and std.mem.eql(u8, old[old.len - 1 - suf], new[new.len - 1 - suf])) suf += 1;
    const removed = old[pre .. old.len - suf];
    const added = new[pre .. new.len - suf];
    const stat: DiffStat = .{ .added = added.len, .removed = removed.len };
    if (removed.len == 0 and added.len == 0) return stat;
    const ctx_before = @min(pre, 3);
    const ctx_after = @min(suf, 3);
    const start = pre - ctx_before;
    try w.print("--- a/{s}\n+++ b/{s}\n@@ -{d},{d} +{d},{d} @@\n", .{
        path,      path,
        start + 1, ctx_before + removed.len + ctx_after,
        start + 1, ctx_before + added.len + ctx_after,
    });
    var budget = max_lines;
    var skipped: usize = 0;
    const Emit = struct {
        fn line(wr: *std.Io.Writer, b: *usize, skip: *usize, mark: u8, text: []const u8) !void {
            if (b.* == 0) {
                skip.* += 1;
                return;
            }
            b.* -= 1;
            try wr.print("{c}{s}\n", .{ mark, std.mem.trimEnd(u8, text, "\r") });
        }
    };
    for (old[start..pre]) |l| try Emit.line(w, &budget, &skipped, ' ', l);
    for (removed) |l| try Emit.line(w, &budget, &skipped, '-', l);
    for (added) |l| try Emit.line(w, &budget, &skipped, '+', l);
    for (old[old.len - suf .. old.len - suf + ctx_after]) |l| try Emit.line(w, &budget, &skipped, ' ', l);
    if (skipped > 0) try w.print("… {d} more diff lines\n", .{skipped});
    return stat;
}

fn splitLines(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (s.len == 0) return out.items;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try out.append(a, l);
    // A trailing newline does not start another line.
    if (s[s.len - 1] == '\n') out.items.len -= 1;
    return out.items;
}

/// Reads a string field of the input.
pub fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

pub fn int(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        else => null,
    };
}

pub fn boolean(v: std.json.Value, key: []const u8) bool {
    if (v != .object) return false;
    const x = v.object.get(key) orelse return false;
    return x == .bool and x.bool;
}

pub fn textOut(a: Allocator, s: []const u8) proto.ToolError!proto.ToolOutput {
    return proto.ToolOutput.text(a, s, false) catch error.OutOfMemory;
}

pub fn errOut(a: Allocator, s: []const u8) proto.ToolError!proto.ToolOutput {
    return proto.ToolOutput.text(a, s, true) catch error.OutOfMemory;
}

/// Turns a rejection into an instruction for the model.
pub fn rejectionText(a: Allocator, rel: []const u8, r: Rejection) Allocator.Error![]const u8 {
    return switch (r) {
        .not_found => std.fmt.allocPrint(a, "old_string was not found in {s}; re-read the file (it may have changed).", .{rel}),
        .not_unique => |n| std.fmt.allocPrint(a, "old_string matches {d} places in {s}; include more surrounding lines to make it unique, or set replace_all.", .{ n, rel }),
        .conflict => |ranges| blk: {
            var out: std.Io.Writer.Allocating = .init(a);
            out.writer.print("The edit conflicts with changes made to {s} since you read it (lines ", .{rel}) catch return error.OutOfMemory;
            for (ranges, 0..) |lr, i| {
                if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
                if (lr.first == lr.last)
                    out.writer.print("{d}", .{lr.first}) catch return error.OutOfMemory
                else
                    out.writer.print("{d}-{d}", .{ lr.first, lr.last }) catch return error.OutOfMemory;
            }
            out.writer.writeAll("); re-read it and try again.") catch return error.OutOfMemory;
            break :blk out.written();
        },
        .stale => std.fmt.allocPrint(a, "{s} changed since you read it; read it again before writing it.", .{rel}),
        .read_only => std.fmt.allocPrint(a, "{s} is read-only.", .{rel}),
        .too_large => std.fmt.allocPrint(a, "The edit to {s} is too large; split it into smaller edits.", .{rel}),
        .already_exists => std.fmt.allocPrint(a, "{s} already exists; read it before overwriting it.", .{rel}),
        .denied => |why| std.fmt.allocPrint(a, "Permission denied: {s}", .{why}),
        .io => |why| std.fmt.allocPrint(a, "Could not write {s}: {s}", .{ rel, why }),
    };
}

/// The result of an accepted proposal: what happened, then the diff.
pub fn outcomeText(a: Allocator, rel: []const u8, verb: []const u8, o: Outcome, before: []const u8, after: []const u8, diff_lines: usize) proto.ToolError!proto.ToolOutput {
    var diff: std.Io.Writer.Allocating = .init(a);
    const st = writeDiff(&diff.writer, a, rel, before, after, diff_lines) catch return error.OutOfMemory;
    const head = switch (o) {
        .applied => try std.fmt.allocPrint(a, "Applied {s} to {s} (+{d} −{d} lines).", .{ verb, rel, st.added, st.removed }),
        .pending => |p| try std.fmt.allocPrint(a, "Proposed {s} to {s} (+{d} −{d} lines) in changeset #{d} — pending review.", .{ verb, rel, st.added, st.removed, p.changeset }),
        .rejected => |r| return errOut(a, try rejectionText(a, rel, r)),
    };
    var o2 = try textOut(a, if (diff.written().len == 0) head else try std.fmt.allocPrint(a, "{s}\n{s}", .{ head, diff.written() }));
    o2.ui_hint = .diff;
    return o2;
}
