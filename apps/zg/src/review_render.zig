//! Output of `zg review` (E12.F03.S05.T01): the changeset table, a
//! changeset's summary and patch, checkpoints, and their NDJSON forms
//! (schema in `docs/review-json.md`).

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_review = @import("zg_review");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Stringify = std.json.Stringify;
const model = zg_review.model;
const Changeset = model.Changeset;
const FileChange = model.FileChange;
const ulid = zg_ai.proto.agent_ref;

/// Context lines around each hunk of a patch.
pub const context_lines = 3;

/// How text output is drawn.
pub const Style = struct {
    /// ANSI SGR colours (a terminal without NO_COLOR).
    color: bool = false,
    /// Lines of tables are cut to this many columns.
    width: u16 = 100,
    /// "Now" for ages.
    now_ms: i64 = 0,

    fn sgr(s: Style, w: *Writer, code: []const u8) Writer.Error!void {
        if (s.color) try w.print("\x1b[{s}m", .{code});
    }
};

const sgr_reset = "0";
const sgr_bold = "1";
const sgr_dim = "2";
const sgr_red = "31";
const sgr_green = "32";
const sgr_yellow = "33";
const sgr_cyan = "36";

// ------------------------------------------------------------ summaries

pub const Counts = struct { files: u32 = 0, added: u32 = 0, removed: u32 = 0, hunks: u32 = 0 };

/// Files, lines and hunks still to decide in `cs` (all of them once it
/// is closed).
pub fn counts(cs: *const Changeset) Counts {
    var c: Counts = .{ .files = @intCast(cs.files.len) };
    for (cs.files) |*f| {
        const n = f.countLines();
        c.added += n.added;
        c.removed += n.removed;
        c.hunks += @intCast(f.hunks.len);
    }
    return c;
}

/// "agent 01J9ZQ", "agent 01J9ZQ/3", "lsp zls", "search_replace", ...
pub fn originText(buf: []u8, o: model.Origin) []const u8 {
    return switch (o) {
        .agent, .inline_edit => blk: {
            const r = o.agentRef().?;
            const id = ulid.format(r.session);
            const kind = if (o == .agent) "agent" else "inline";
            break :blk if (r.agent == 0)
                std.fmt.bufPrint(buf, "{s} {s}", .{ kind, id[0..6] }) catch buf
            else
                std.fmt.bufPrint(buf, "{s} {s}/{d}", .{ kind, id[0..6], r.agent }) catch buf;
        },
        .lsp => |l| std.fmt.bufPrint(buf, "lsp {s}", .{l.server}) catch buf,
        else => @tagName(o),
    };
}

/// "now", "5m", "3h", "2d".
pub fn ageText(buf: []u8, now_ms: i64, then_ms: i64) []const u8 {
    const s = @divFloor(@max(0, now_ms - then_ms), std.time.ms_per_s);
    if (s < 60) return "now";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@divFloor(s, 60)}) catch buf;
    if (s < 86400) return std.fmt.bufPrint(buf, "{d}h", .{@divFloor(s, 3600)}) catch buf;
    return std.fmt.bufPrint(buf, "{d}d", .{@divFloor(s, 86400)}) catch buf;
}

fn opLetter(op: model.FileOp) u8 {
    return switch (op) {
        .create => 'A',
        .modify => 'M',
        .delete => 'D',
        .rename => 'R',
        .set_executable => 'X',
    };
}

fn stateColor(s: model.State) []const u8 {
    return switch (s) {
        .pending, .partially_applied, .open_batch => sgr_yellow,
        .applied => sgr_green,
        .rejected, .superseded, .discarded => sgr_dim,
    };
}

/// `line` cut to `width` columns (bytes on a UTF-8 boundary; the table's
/// text is mostly ASCII).
fn cut(line: []const u8, width: u16) []const u8 {
    if (line.len <= width) return line;
    var n: usize = width;
    while (n > 0 and (line[n] & 0xC0) == 0x80) n -= 1;
    return line[0..n];
}

/// One table row per changeset, newest last as submitted.
pub fn writeTable(w: *Writer, style: Style, list: []const *const Changeset) Writer.Error!void {
    if (list.len == 0) return w.writeAll("No changesets.\n");
    var line: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&line, "{s:<6} {s:<17} {s:>5} {s:<11} {s:>4}  {s:<16} {s}", .{ "ID", "STATE", "FILES", "+/-", "AGE", "ORIGIN", "LABEL" }) catch &line;
    try style.sgr(w, sgr_bold);
    try w.writeAll(cut(head, style.width));
    try style.sgr(w, sgr_reset);
    try w.writeByte('\n');
    for (list) |cs| {
        const c = counts(cs);
        var id_buf: [24]u8 = undefined;
        var lines_buf: [24]u8 = undefined;
        var age_buf: [16]u8 = undefined;
        var origin_buf: [64]u8 = undefined;
        const row = std.fmt.bufPrint(&line, "{s:<6} {s:<17} {d:>5} {s:<11} {s:>4}  {s:<16} {s}", .{
            std.fmt.bufPrint(&id_buf, "{f}", .{cs.id}) catch "",
            @tagName(cs.state),
            c.files,
            std.fmt.bufPrint(&lines_buf, "+{d} -{d}", .{ c.added, c.removed }) catch "",
            ageText(&age_buf, style.now_ms, cs.created_ms),
            originText(&origin_buf, cs.prov.origin),
            cs.prov.label,
        }) catch &line;
        const shown = cut(row, style.width);
        if (!style.color) {
            try w.print("{s}\n", .{shown});
            continue;
        }
        // Colour the state column (bytes 7..24) when it is visible.
        const a = @min(shown.len, 7);
        const b = @min(shown.len, 24);
        try w.writeAll(shown[0..a]);
        try style.sgr(w, stateColor(cs.state));
        try w.writeAll(shown[a..b]);
        try style.sgr(w, sgr_reset);
        try w.print("{s}\n", .{shown[b..]});
    }
}

/// The header block of `show`: what made it, then one line per file.
pub fn writeSummary(w: *Writer, style: Style, cs: *const Changeset) Writer.Error!void {
    const c = counts(cs);
    try style.sgr(w, sgr_bold);
    try w.print("{f} {s}", .{ cs.id, cs.prov.label });
    try style.sgr(w, sgr_reset);
    try w.writeAll("  ");
    try style.sgr(w, stateColor(cs.state));
    try w.writeAll(@tagName(cs.state));
    try style.sgr(w, sgr_reset);
    if (cs.auto_applied) try w.writeAll(" (auto-applied)");
    try w.writeByte('\n');
    switch (cs.prov.origin) {
        .agent => |a| {
            const id = ulid.format(a.ref.session);
            try w.print("origin: agent, session {s}", .{&id});
            if (a.ref.agent != 0) try w.print(", subagent {d}", .{a.ref.agent});
            try w.print(", turn {d}, model {s}\n", .{ a.turn, a.model });
        },
        else => {
            var buf: [64]u8 = undefined;
            try w.print("origin: {s}\n", .{originText(&buf, cs.prov.origin)});
        },
    }
    if (cs.prov.rationale) |r| try w.print("why: {s}\n", .{r});
    var age_buf: [16]u8 = undefined;
    try w.print("created {s} ago; {d} file{s}, +{d} -{d}, {d} hunk{s} open\n", .{
        ageText(&age_buf, style.now_ms, cs.created_ms),
        c.files,
        plural(c.files),
        c.added,
        c.removed,
        c.hunks,
        plural(c.hunks),
    });
    for (cs.files) |*f| {
        const n = f.countLines();
        try w.print("  {c} {s}", .{ opLetter(f.op), f.path });
        switch (f.op) {
            .rename => |r| try w.print(" (from {s})", .{r.from}),
            .set_executable => |on| try w.print(" ({s} executable)", .{if (on) "make" else "clear"}),
            else => {},
        }
        try w.print("  {s}", .{@tagName(f.state)});
        if (f.hunks.len > 0) try w.print("  +{d} -{d}, {d} hunk{s}", .{ n.added, n.removed, f.hunks.len, plural(@intCast(f.hunks.len)) });
        if (f.content == .binary) try w.writeAll("  binary");
        try w.writeByte('\n');
    }
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}

// --------------------------------------------------------------- patches

/// The lines of `text` without their terminators.
pub fn splitLines(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        var line = text[i..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try out.append(arena, line);
        i = nl + 1;
    }
    return out.items;
}

/// A file's base text and its text with every open hunk taken.
pub const Texts = struct { base: []const u8, new: []const u8 };

pub fn texts(arena: Allocator, blobs: model.Blobs, f: *const FileChange) !?Texts {
    const t = switch (f.content) {
        .text => |*t| t,
        else => return null,
    };
    const base: []const u8 = if (t.base) |b| try blobs.get(arena, b.hash) orelse return error.MissingBlob else "";
    return .{ .base = base, .new = try t.edits.applyToSlice(arena, base) };
}

/// The hunk's lines with context: `[ctx_before][removed][added][ctx_after]`
/// as unified-diff ranges (1-based starts).
pub const HunkLines = struct {
    base_start: u32,
    base_count: u32,
    new_start: u32,
    new_count: u32,
    before: []const []const u8,
    removed: []const []const u8,
    added: []const []const u8,
    after: []const []const u8,
};

/// Context stops at the neighbouring hunks, so it is the same text on
/// both sides.
pub fn hunkLines(f: *const FileChange, i: usize, base: []const []const u8, new: []const []const u8) HunkLines {
    const h = f.hunks[i];
    const lo = if (i > 0) f.hunks[i - 1].base_lines.end() else 0;
    const hi: u32 = if (i + 1 < f.hunks.len) f.hunks[i + 1].base_lines.start else @intCast(base.len);
    const bs = @min(h.base_lines.start, @as(u32, @intCast(base.len)));
    const be = @min(h.base_lines.end(), @as(u32, @intCast(base.len)));
    const ns = @min(h.new_lines.start, @as(u32, @intCast(new.len)));
    const ne = @min(h.new_lines.end(), @as(u32, @intCast(new.len)));
    const before = @min(context_lines, bs - @min(bs, lo));
    const after = @min(context_lines, hi -| be);
    const total_before = before;
    return .{
        .base_start = bs - total_before + 1,
        .base_count = (be - bs) + before + after,
        .new_start = ns - total_before + 1,
        .new_count = (ne - ns) + before + after,
        .before = base[bs - before .. bs],
        .removed = base[bs..be],
        .added = new[ns..ne],
        .after = base[be .. be + after],
    };
}

/// "pending", "conflicted", "accepted", ...
pub fn hunkState(h: model.Hunk) []const u8 {
    if (h.decision == .undecided) return if (h.conflict != null) "conflicted" else "pending";
    return @tagName(h.decision);
}

/// A unified diff of `f`, each hunk header extended with its number and
/// state: `@@ -a,b +c,d @@ hunk 2 [pending]`.
pub fn writePatch(w: *Writer, arena: Allocator, style: Style, blobs: model.Blobs, f: *const FileChange) !void {
    const from: []const u8 = switch (f.op) {
        .create => "/dev/null",
        .rename => |r| r.from,
        else => f.path,
    };
    try style.sgr(w, sgr_bold);
    if (f.op == .create) try w.print("--- {s}\n", .{from}) else try w.print("--- a/{s}\n", .{from});
    if (f.op == .delete) try w.writeAll("+++ /dev/null\n") else try w.print("+++ b/{s}\n", .{f.path});
    try style.sgr(w, sgr_reset);
    switch (f.op) {
        .delete => return w.writeAll("deleted file\n"),
        .set_executable => |on| try w.print("{s} the executable bit\n", .{if (on) "sets" else "clears"}),
        else => {},
    }
    if (f.content == .binary) return w.writeAll("Binary file changed\n");
    const t = try texts(arena, blobs, f) orelse return;
    const base = try splitLines(arena, t.base);
    const new = try splitLines(arena, t.new);
    for (0..f.hunks.len) |i| {
        const hl = hunkLines(f, i, base, new);
        try style.sgr(w, sgr_cyan);
        try w.print("@@ -{d},{d} +{d},{d} @@", .{ hl.base_start, hl.base_count, hl.new_start, hl.new_count });
        try style.sgr(w, sgr_reset);
        try w.print(" hunk {d} [{s}]\n", .{ i + 1, hunkState(f.hunks[i]) });
        for (hl.before) |l| try w.print(" {s}\n", .{l});
        for (hl.removed) |l| try diffLine(w, style, '-', l);
        for (hl.added) |l| try diffLine(w, style, '+', l);
        for (hl.after) |l| try w.print(" {s}\n", .{l});
    }
}

fn diffLine(w: *Writer, style: Style, sign: u8, line: []const u8) Writer.Error!void {
    try style.sgr(w, if (sign == '-') sgr_red else sgr_green);
    try w.print("{c}{s}", .{ sign, line });
    try style.sgr(w, sgr_reset);
    try w.writeByte('\n');
}

// ------------------------------------------------------------ checkpoints

pub fn writeCheckpoints(w: *Writer, style: Style, list: []const model.Checkpoint) Writer.Error!void {
    if (list.len == 0) return w.writeAll("No checkpoints.\n");
    var line: [512]u8 = undefined;
    const head = std.fmt.bufPrint(&line, "{s:<6} {s:>4}  {s:<10} {s:>4}  {s}", .{ "ID", "AGE", "SESSION", "TURN", "LABEL" }) catch &line;
    try style.sgr(w, sgr_bold);
    try w.writeAll(cut(head, style.width));
    try style.sgr(w, sgr_reset);
    try w.writeByte('\n');
    for (list) |cp| {
        var age_buf: [16]u8 = undefined;
        var sess_buf: [16]u8 = undefined;
        const id = ulid.format(cp.session);
        const sess = if (cp.agent == 0)
            std.fmt.bufPrint(&sess_buf, "{s}", .{id[0..6]}) catch ""
        else
            std.fmt.bufPrint(&sess_buf, "{s}/{d}", .{ id[0..6], cp.agent }) catch "";
        const row = std.fmt.bufPrint(&line, "{d:<6} {s:>4}  {s:<10} {d:>4}  {s}{s}", .{
            cp.id,
            ageText(&age_buf, style.now_ms, cp.created_ms),
            sess,
            cp.turn,
            cp.label,
            if (cp.pinned) " (pinned)" else "",
        }) catch &line;
        try w.print("{s}\n", .{cut(row, style.width)});
    }
}

// ------------------------------------------------------------------- JSON

/// `{"type":"changeset",...}` on one line.
pub fn jsonChangeset(w: *Writer, cs: *const Changeset) Writer.Error!void {
    const c = counts(cs);
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "type", "changeset");
    try field(&s, "id", @intFromEnum(cs.id));
    try field(&s, "state", @tagName(cs.state));
    try field(&s, "label", cs.prov.label);
    try field(&s, "origin", @tagName(cs.prov.origin));
    if (cs.prov.origin.agentRef()) |r| {
        const id = ulid.format(r.session);
        try field(&s, "session", &id);
        try field(&s, "agent", r.agent);
    } else {
        try field(&s, "session", null);
        try field(&s, "agent", null);
    }
    try field(&s, "turn", switch (cs.prov.origin) {
        .agent => |a| a.turn,
        else => null,
    });
    try field(&s, "rationale", cs.prov.rationale);
    try field(&s, "created_ms", cs.created_ms);
    try field(&s, "decided_ms", cs.decided_ms);
    try field(&s, "auto_applied", cs.auto_applied);
    try field(&s, "checkpoint", cs.checkpoint);
    try field(&s, "files", c.files);
    try field(&s, "added", c.added);
    try field(&s, "removed", c.removed);
    try field(&s, "hunks", c.hunks);
    try s.endObject();
    try w.writeByte('\n');
}

pub fn jsonFile(w: *Writer, cs: *const Changeset, f: *const FileChange) Writer.Error!void {
    const n = f.countLines();
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "type", "file");
    try field(&s, "changeset", @intFromEnum(cs.id));
    try field(&s, "path", f.path);
    try field(&s, "op", @tagName(f.op));
    try field(&s, "from", switch (f.op) {
        .rename => |r| r.from,
        else => null,
    });
    try field(&s, "state", @tagName(f.state));
    try field(&s, "binary", f.content == .binary);
    try field(&s, "added", n.added);
    try field(&s, "removed", n.removed);
    try field(&s, "hunks", f.hunks.len);
    try s.endObject();
    try w.writeByte('\n');
}

/// A hunk; `lines` (from `hunkLines`) adds its removed and added text.
pub fn jsonHunk(w: *Writer, cs: *const Changeset, f: *const FileChange, i: usize, lines: ?HunkLines) Writer.Error!void {
    const h = f.hunks[i];
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "type", "hunk");
    try field(&s, "changeset", @intFromEnum(cs.id));
    try field(&s, "path", f.path);
    try field(&s, "hunk", i + 1);
    try field(&s, "state", hunkState(h));
    try field(&s, "base_start", h.base_lines.start + 1);
    try field(&s, "base_count", h.base_lines.count);
    try field(&s, "new_start", h.new_lines.start + 1);
    try field(&s, "new_count", h.new_lines.count);
    try field(&s, "conflict", if (h.conflict) |cf| @tagName(cf.kind) else null);
    if (lines) |l| {
        try field(&s, "removed_lines", l.removed);
        try field(&s, "added_lines", l.added);
    }
    try s.endObject();
    try w.writeByte('\n');
}

pub fn jsonCheckpoint(w: *Writer, cp: model.Checkpoint) Writer.Error!void {
    const id = ulid.format(cp.session);
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "type", "checkpoint");
    try field(&s, "id", cp.id);
    try field(&s, "session", &id);
    try field(&s, "agent", cp.agent);
    try field(&s, "turn", cp.turn);
    try field(&s, "label", cp.label);
    try field(&s, "created_ms", cp.created_ms);
    try field(&s, "pinned", cp.pinned);
    try s.endObject();
    try w.writeByte('\n');
}

fn field(s: *Stringify, name: []const u8, v: anytype) Writer.Error!void {
    try s.objectField(name);
    try s.write(v);
}
