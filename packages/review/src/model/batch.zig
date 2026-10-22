//! A batch being built: the file operations of one producer (an agent
//! turn, a replace-all) before they become a changeset
//! (E12.F01.S01.T02). Operations on the same path combine:
//!
//! | first  | then   | result                                  |
//! |--------|--------|-----------------------------------------|
//! | edit   | edit   | one edit (`compose`)                    |
//! | create | edit   | create with the edited text             |
//! | edit   | delete | delete of the original base             |
//! | create | delete | nothing                                 |
//! | delete | create | edit replacing the whole base           |
//! | rename | edit   | rename with the edit                    |
//!
//! Anything else on one path (create over an existing entry, an edit after
//! a delete, a rename onto a used path) is `error.InvalidBatch`.
//!
//! Each later edit applies to the text the earlier ones produced, which is
//! what an agent reading its own pending edits sees. A batch owns an arena
//! for its texts and owns its ChangeSets.

const std = @import("std");
const changeset = @import("changeset.zig");
const provenance = @import("provenance.zig");

const Allocator = std.mem.Allocator;
const ChangeSet = changeset.ChangeSet;
const Replace = changeset.Replace;
const Provenance = provenance.Provenance;

pub const Error = error{ InvalidBatch, PathOutsideWorkspace, OutOfMemory };

/// One path's combined operation.
pub const Entry = struct {
    /// Workspace-relative, `/`-separated.
    path: []const u8,
    /// Rename source.
    from: ?[]const u8 = null,
    /// The text the edits or the delete apply to (null for creates and
    /// renames without edits).
    base: ?[]const u8 = null,
    base_version: ?u64 = null,
    /// The whole new text of a create.
    created: ?[]const u8 = null,
    edits: ?ChangeSet = null,
    deleted: bool = false,
    executable: ?bool = null,

    fn deinitEdits(e: *Entry) void {
        if (e.edits) |*cs| cs.deinit();
        e.edits = null;
    }
};

pub const Batch = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    prov: Provenance,
    /// The workspace root (absolute, normalised) paths are checked against.
    root: []const u8,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator, root: []const u8, prov: Provenance) Error!*Batch {
        const b = try gpa.create(Batch);
        b.* = .{ .gpa = gpa, .arena = .init(gpa), .prov = undefined, .root = undefined };
        errdefer b.deinit();
        const a = b.arena.allocator();
        b.root = try a.dupe(u8, root);
        b.prov = try copyProvenance(a, prov);
        return b;
    }

    pub fn deinit(b: *Batch) void {
        for (b.entries.items) |*e| e.deinitEdits();
        b.arena.deinit();
        b.gpa.destroy(b);
    }

    fn find(b: *Batch, path: []const u8) ?*Entry {
        for (b.entries.items) |*e| if (std.mem.eql(u8, e.path, path)) return e;
        return null;
    }

    fn norm(b: *Batch, path: []const u8) Error![]const u8 {
        return normalizePath(b.arena.allocator(), b.root, path);
    }

    /// `edits` change `base` (the file's text as the producer saw it,
    /// after any earlier operation of this batch on the path).
    pub fn addEdit(b: *Batch, path_in: []const u8, base: []const u8, base_version: ?u64, edits: *const ChangeSet) Error!void {
        const a = b.arena.allocator();
        const path = try b.norm(path_in);
        if (edits.base_len != base.len) return error.InvalidBatch;
        if (b.find(path)) |e| {
            if (e.deleted) return error.InvalidBatch;
            if (e.created) |c| {
                if (!std.mem.eql(u8, c, base)) return error.InvalidBatch;
                e.created = try edits.applyToSlice(a, c);
                return;
            }
            if (e.edits) |*old| {
                if (old.newLen() != edits.base_len) return error.InvalidBatch;
                const composed = try old.compose(edits, b.gpa);
                old.deinit();
                e.edits = composed;
                return;
            }
            // A rename or mode change gets its content.
            e.base = try a.dupe(u8, base);
            e.base_version = base_version;
            e.edits = try edits.clone(b.gpa);
            return;
        }
        var cs = try edits.clone(b.gpa);
        errdefer cs.deinit();
        try b.entries.append(a, .{ .path = path, .base = try a.dupe(u8, base), .base_version = base_version, .edits = cs });
    }

    pub fn addCreate(b: *Batch, path_in: []const u8, bytes: []const u8) Error!void {
        const a = b.arena.allocator();
        const path = try b.norm(path_in);
        if (b.find(path)) |e| {
            if (!e.deleted) return error.InvalidBatch;
            // Delete then create: one edit over the whole base.
            const base = e.base.?;
            e.deleted = false;
            e.edits = ChangeSet.fromEdits(b.gpa, base.len, &.{.{ .range = .{ .start = 0, .end = base.len }, .text = bytes }}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Overlap, error.OutOfBounds => unreachable,
            };
            return;
        }
        try b.entries.append(a, .{ .path = path, .created = try a.dupe(u8, bytes) });
    }

    /// `base` is the text being deleted (checked again when applied).
    pub fn addDelete(b: *Batch, path_in: []const u8, base: []const u8) Error!void {
        const a = b.arena.allocator();
        const path = try b.norm(path_in);
        if (b.find(path)) |e| {
            if (e.deleted or e.from != null) return error.InvalidBatch;
            if (e.created != null) {
                const i = (@intFromPtr(e) - @intFromPtr(b.entries.items.ptr)) / @sizeOf(Entry);
                _ = b.entries.orderedRemove(i);
                return;
            }
            e.deinitEdits();
            e.deleted = true;
            e.executable = null;
            return;
        }
        try b.entries.append(a, .{ .path = path, .base = try a.dupe(u8, base), .deleted = true });
    }

    pub fn addRename(b: *Batch, from_in: []const u8, to_in: []const u8) Error!void {
        const a = b.arena.allocator();
        const from = try b.norm(from_in);
        const to = try b.norm(to_in);
        if (std.mem.eql(u8, from, to) or b.find(to) != null) return error.InvalidBatch;
        if (b.find(from)) |e| {
            if (e.deleted or e.created != null or e.from != null) return error.InvalidBatch;
            e.from = from;
            e.path = to;
            return;
        }
        try b.entries.append(a, .{ .path = to, .from = from });
    }

    pub fn setExecutable(b: *Batch, path_in: []const u8, on: bool) Error!void {
        const path = try b.norm(path_in);
        if (b.find(path)) |e| {
            if (e.deleted) return error.InvalidBatch;
            e.executable = on;
            return;
        }
        try b.entries.append(b.arena.allocator(), .{ .path = path, .executable = on });
    }
};

/// A deep copy of `p` in `a`.
pub fn copyProvenance(a: Allocator, p: Provenance) Allocator.Error!Provenance {
    var out = p;
    out.label = try a.dupe(u8, p.label);
    if (p.rationale) |r| out.rationale = try a.dupe(u8, r);
    out.workspace = try a.dupe(u8, p.workspace);
    if (p.lane) |l| out.lane = try a.dupe(u8, l);
    const calls = try a.alloc([]const u8, p.tool_calls.len);
    for (calls, p.tool_calls) |*d, s| d.* = try a.dupe(u8, s);
    out.tool_calls = calls;
    switch (out.origin) {
        inline else => |*v| inline for (std.meta.fields(@TypeOf(v.*))) |f| {
            const x = &@field(v.*, f.name);
            switch (f.type) {
                []const u8 => x.* = try a.dupe(u8, x.*),
                @import("zg_ai_proto").AgentRef => x.* = try copyRef(a, x.*),
                ?@import("zg_ai_proto").AgentRef => if (x.*) |r| {
                    x.* = try copyRef(a, r);
                },
                else => {},
            }
        },
    }
    return out;
}

fn copyRef(a: Allocator, r: @import("zg_ai_proto").AgentRef) Allocator.Error!@import("zg_ai_proto").AgentRef {
    var out = r;
    if (r.tool_call) |t| out.tool_call = try a.dupe(u8, t);
    return out;
}

/// `path` as a workspace-relative, `/`-separated path without `.`
/// segments. Absolute paths must be under `root`. Paths that leave the
/// workspace, and paths inside `.git/` or `.zigguro/review/`, are
/// rejected.
pub fn normalizePath(a: Allocator, root: []const u8, path: []const u8) Error![]const u8 {
    var buf = try a.dupe(u8, path);
    for (buf) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    var root_n = std.mem.trimEnd(u8, root, "/\\");
    var rel: []const u8 = buf;
    const is_abs = buf.len > 0 and (buf[0] == '/' or (buf.len > 2 and buf[1] == ':' and buf[2] == '/'));
    if (is_abs) {
        const rbuf = try a.dupe(u8, root_n);
        for (rbuf) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        root_n = rbuf;
        if (!std.mem.startsWith(u8, buf, root_n) or (buf.len > root_n.len and buf[root_n.len] != '/')) return error.PathOutsideWorkspace;
        rel = buf[root_n.len..];
    }
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len == 0) return error.PathOutsideWorkspace;
            _ = parts.pop();
            continue;
        }
        try parts.append(a, seg);
    }
    if (parts.items.len == 0) return error.PathOutsideWorkspace;
    const out = try std.mem.join(a, "/", parts.items);
    if (std.mem.eql(u8, parts.items[0], ".git")) return error.PathOutsideWorkspace;
    if (parts.items.len >= 2 and std.mem.eql(u8, parts.items[0], ".zigguro") and std.mem.eql(u8, parts.items[1], "review")) return error.PathOutsideWorkspace;
    return out;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testProv() Provenance {
    return .{ .origin = .{ .user_bulk = .{ .command = "test" } }, .label = "L", .workspace = "/w", .created_ms = 0 };
}

fn cs1(base_len: u64, s: u64, e: u64, t: []const u8) !ChangeSet {
    return ChangeSet.fromEdits(testing.allocator, base_len, &.{.{ .range = .{ .start = s, .end = e }, .text = t }});
}

test "queue: path outside workspace / .git rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("src/a.zig", try normalizePath(a, "/w", "src/./a.zig"));
    try testing.expectEqualStrings("src/a.zig", try normalizePath(a, "/w/", "/w/src/a.zig"));
    try testing.expectEqualStrings("a.zig", try normalizePath(a, "C:\\w", "C:\\w\\x\\..\\a.zig"));
    try testing.expectError(error.PathOutsideWorkspace, normalizePath(a, "/w", "../x"));
    try testing.expectError(error.PathOutsideWorkspace, normalizePath(a, "/w", "/wx/a"));
    try testing.expectError(error.PathOutsideWorkspace, normalizePath(a, "/w", "/etc/passwd"));
    try testing.expectError(error.PathOutsideWorkspace, normalizePath(a, "/w", ".git/config"));
    try testing.expectError(error.PathOutsideWorkspace, normalizePath(a, "/w", ".zigguro/review/lock"));
    try testing.expectError(error.PathOutsideWorkspace, normalizePath(a, "/w", "."));
    try testing.expectEqualStrings(".zigguro/notes.md", try normalizePath(a, "/w", ".zigguro/notes.md"));
}

test "queue: duplicate-path normalisation table" {
    const b = try Batch.init(testing.allocator, "/w", testProv());
    defer b.deinit();

    // edit + edit: composed.
    var e1 = try cs1(5, 0, 1, "H");
    defer e1.deinit();
    var e2 = try cs1(5, 4, 5, "O");
    defer e2.deinit();
    try b.addEdit("a", "hello", 1, &e1);
    try b.addEdit("a", "Hello", null, &e2);
    const a_txt = try b.entries.items[0].edits.?.applyToSlice(testing.allocator, "hello");
    defer testing.allocator.free(a_txt);
    try testing.expectEqualStrings("HellO", a_txt);
    try testing.expectEqual(@as(?u64, 1), b.entries.items[0].base_version);

    // create + edit: create with the edited text.
    try b.addCreate("c", "new");
    var e3 = try cs1(3, 3, 3, "!");
    defer e3.deinit();
    try b.addEdit("c", "new", null, &e3);
    try testing.expectEqualStrings("new!", b.entries.items[1].created.?);

    // edit + delete: delete of the original base.
    try b.addDelete("a", "HellO");
    try testing.expect(b.entries.items[0].deleted);
    try testing.expectEqual(@as(?ChangeSet, null), b.entries.items[0].edits);
    try testing.expectEqualStrings("hello", b.entries.items[0].base.?);

    // create + delete: nothing.
    try b.addDelete("c", "new!");
    try testing.expectEqual(@as(usize, 1), b.entries.items.len);

    // delete + create: a whole-file edit.
    try b.addCreate("a", "bye");
    const back = try b.entries.items[0].edits.?.applyToSlice(testing.allocator, "hello");
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("bye", back);

    // rename + edit.
    try b.addRename("r", "s");
    var e4 = try cs1(2, 0, 0, ">");
    defer e4.deinit();
    try b.addEdit("s", "xy", null, &e4);
    try testing.expectEqualStrings("r", b.entries.items[1].from.?);
    try testing.expect(b.entries.items[1].edits != null);

    // Invalid combinations.
    try testing.expectError(error.InvalidBatch, b.addCreate("s", "x"));
    try testing.expectError(error.InvalidBatch, b.addRename("a", "s"));
    try b.addDelete("d", "x");
    var e5 = try cs1(1, 0, 0, "y");
    defer e5.deinit();
    try testing.expectError(error.InvalidBatch, b.addEdit("d", "x", null, &e5));
    // A base that does not match the edits.
    try testing.expectError(error.InvalidBatch, b.addEdit("z", "toolong", null, &e5));
}

test "batch: provenance is copied" {
    var label = "Turn 1".*;
    var p = testProv();
    p.label = &label;
    const b = try Batch.init(testing.allocator, "/w", p);
    defer b.deinit();
    label[0] = 'X';
    try testing.expectEqualStrings("Turn 1", b.prov.label);
}
