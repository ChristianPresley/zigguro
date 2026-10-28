//! The prompt library (E13.F08.S02.T01): one index over project prompts
//! (`.zigguro/prompts/**/*.md`), the user's (`<config>/prompts/**/*.md`),
//! built-ins (document actions `doc/*`, research prompts `research/*`) and
//! E10 skills. Project entries shadow user ones, which shadow built-ins,
//! so a user overrides a built-in by creating the same id. Only headers are
//! read when indexing; bodies load on first use.
//!
//! Search is fuzzy over id, title, tags and description, boosted by how
//! often an entry was used in this workspace (`.zigguro/state/library.zon`).

const std = @import("std");
const zg_ai = @import("zg_ai");
const entry_mod = @import("entry.zig");
const template = @import("template.zig");
const builtin = @import("builtin.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const SkillIndex = zg_ai.ext.SkillIndex;

pub const Entry = entry_mod.Entry;
pub const EntrySource = entry_mod.EntrySource;
pub const VarDecl = template.VarDecl;

/// Folders the library reads; each optional.
pub const Dirs = struct {
    /// `<workspace>/.zigguro/prompts`.
    project: ?Io.Dir = null,
    /// `<config>/prompts`.
    user: ?Io.Dir = null,
    /// `<workspace>/.zigguro/state`, for usage counts.
    state: ?Io.Dir = null,
};

pub const Hit = struct { entry: *const Entry, score: i32 };

/// How much of a file indexing reads: enough for any sane frontmatter.
pub const head_bytes = 8 * 1024;
const max_body_bytes = 1 << 20;
const usage_file = "library.zon";

pub const NewEntry = struct {
    /// "research/lead"; segments `[a-z0-9._-]`.
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    variables: []const VarDecl = &.{},
    body: []const u8,
};

/// Writes a new prompt file. Project files go through an E12 changeset
/// (`changeset` is its id); user files are written directly.
pub const WritePort = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, scope: Scope, rel_path: []const u8, bytes: []const u8) anyerror!?u64,
};

pub const Scope = enum { project, user };

pub const Error = error{ InvalidId, AlreadyExists, NoWritePort, UnknownEntry } || Allocator.Error;

gpa: Allocator,
io: Io,
dirs: Dirs,
skills: ?*SkillIndex,
writer: ?WritePort = null,

mutex: Io.Mutex = .init,
/// Owns entries; replaced on `reload`.
arena: std.heap.ArenaAllocator,
/// Winning entries (shadowed ones dropped), skills last.
entries: std.ArrayList(Entry) = .empty,
by_id: std.StringHashMapUnmanaged(u32) = .empty,
/// Lives as long as the library: bodies read so far (by id), usage counts.
cache_arena: std.heap.ArenaAllocator,
bodies: std.StringHashMapUnmanaged([]const u8) = .empty,
usage: std.StringHashMapUnmanaged(u32) = .empty,
/// Number of times a file body was read (tests check laziness).
body_reads: u32 = 0,

const PromptLibrary = @This();

pub fn open(gpa: Allocator, io: Io, dirs: Dirs, skills: ?*SkillIndex) !*PromptLibrary {
    const l = try gpa.create(PromptLibrary);
    errdefer gpa.destroy(l);
    l.* = .{ .gpa = gpa, .io = io, .dirs = dirs, .skills = skills, .arena = .init(gpa), .cache_arena = .init(gpa) };
    errdefer l.deinitParts();
    l.loadUsage();
    try l.rebuild();
    return l;
}

pub fn deinit(l: *PromptLibrary) void {
    l.deinitParts();
    l.gpa.destroy(l);
}

fn deinitParts(l: *PromptLibrary) void {
    l.entries.deinit(l.gpa);
    l.by_id.deinit(l.gpa);
    l.bodies.deinit(l.gpa);
    l.usage.deinit(l.gpa);
    l.arena.deinit();
    l.cache_arena.deinit();
}

/// Rescans every folder (the app calls this on E08 file events under the
/// prompt folders).
pub fn reload(l: *PromptLibrary) !void {
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    l.bodies.clearRetainingCapacity();
    l.entries.clearRetainingCapacity();
    l.by_id.clearRetainingCapacity();
    _ = l.arena.reset(.retain_capacity);
    try l.rebuildLocked();
}

fn rebuild(l: *PromptLibrary) !void {
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    try l.rebuildLocked();
}

fn rebuildLocked(l: *PromptLibrary) !void {
    // Highest precedence first; later sources skip ids already present.
    if (l.dirs.project) |d| try l.scanDir(d, .project);
    if (l.dirs.user) |d| try l.scanDir(d, .user);
    const a = l.arena.allocator();
    for (builtin.entries()) |b| {
        if (l.by_id.contains(b.id)) continue;
        const t = template.parse(a, b.body, null) catch return error.InvalidBuiltin;
        try l.add(.{
            .id = b.id,
            .source = .builtin,
            .title = b.title,
            .description = b.description,
            .tags = b.tags,
            .variables = try template.variables(a, t, b.variables),
            .body_hash = entry_mod.hashBody(b.body),
        });
    }
    if (l.skills) |ix| {
        const list = try ix.list(a);
        for (list) |s| {
            if (!s.user_invocable) continue;
            const id = try std.fmt.allocPrint(a, "/{s}", .{s.name});
            if (l.by_id.contains(id)) continue;
            try l.add(.{
                .id = id,
                .source = .skill,
                .title = s.name,
                .description = s.description,
                .path = s.body_path,
                .disable_model_invocation = s.disable_model_invocation,
                .argument_hint = s.argument_hint,
            });
        }
    }
}

fn add(l: *PromptLibrary, e: Entry) !void {
    try l.by_id.put(l.gpa, e.id, @intCast(l.entries.items.len));
    try l.entries.append(l.gpa, e);
}

fn scanDir(l: *PromptLibrary, dir: Io.Dir, source: EntrySource) !void {
    const a = l.arena.allocator();
    var walker = try dir.walk(l.gpa);
    defer walker.deinit();
    var head: [head_bytes]u8 = undefined;
    while (walker.next(l.io) catch null) |w| {
        if (w.kind != .file) continue;
        const id = try entry_mod.idFromRelPath(a, w.path) orelse continue;
        if (l.by_id.contains(id)) continue;
        const f = dir.openFile(l.io, w.path, .{}) catch continue;
        defer f.close(l.io);
        const n = f.readPositionalAll(l.io, &head, 0) catch continue;
        const h = try entry_mod.parseHeader(a, head[0..n]);
        try l.add(.{
            .id = id,
            .source = source,
            .title = if (h.title) |t| try a.dupe(u8, t) else try entry_mod.titleFromId(a, id),
            .description = try a.dupe(u8, h.description),
            .tags = try dupeList(a, h.tags),
            .variables = try dupeVars(a, h.variables),
            .path = try a.dupe(u8, w.path),
        });
    }
}

fn dupeList(a: Allocator, xs: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, xs.len);
    for (xs, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
}

fn dupeVars(a: Allocator, vs: []const VarDecl) ![]const VarDecl {
    const out = try a.alloc(VarDecl, vs.len);
    for (vs, out) |v, *o| o.* = .{
        .name = try a.dupe(u8, v.name),
        .kind = v.kind,
        .options = try dupeList(a, v.options),
        .default = if (v.default) |d| try a.dupe(u8, d) else null,
        .required = v.required,
    };
    return out;
}

/// The entry `id` (`/name` for skills). Valid until the next `reload`.
pub fn get(l: *PromptLibrary, id: []const u8) ?*const Entry {
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    const i = l.by_id.get(id) orelse return null;
    return &l.entries.items[i];
}

pub fn count(l: *PromptLibrary) usize {
    return l.entries.items.len;
}

/// All entries, in index order (project, user, built-in, skills).
pub fn all(l: *PromptLibrary) []const Entry {
    return l.entries.items;
}

/// The body text of `id` (without frontmatter), read on first use and
/// cached until `reload`. Also fills in the entry's `body_hash`.
pub fn body(l: *PromptLibrary, id: []const u8, arena: Allocator) ![]const u8 {
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    if (l.bodies.get(id)) |b| return arena.dupe(u8, b);
    const i = l.by_id.get(id) orelse return error.UnknownEntry;
    const e = &l.entries.items[i];
    const ca = l.cache_arena.allocator();
    const text: []const u8 = switch (e.source) {
        .builtin => builtin.find(id).?.body,
        .project, .user => blk: {
            const dir = (if (e.source == .project) l.dirs.project else l.dirs.user).?;
            l.body_reads += 1;
            const bytes = try dir.readFileAlloc(l.io, e.path, ca, .limited(max_body_bytes));
            const h = try entry_mod.parseHeader(ca, bytes);
            break :blk bytes[h.body_start..];
        },
        .skill => blk: {
            const s = l.skills.?.find(id[1..]) orelse return error.UnknownEntry;
            break :blk try s.body(l.io, ca);
        },
    };
    e.body_hash = entry_mod.hashBody(text);
    // Inline hints (`{{x|choice:a,b}}`) and undeclared names join the
    // frontmatter's declarations once the body is known.
    if (e.source == .project or e.source == .user) {
        if (template.parse(ca, text, null)) |t| {
            e.variables = try template.variables(ca, t, e.variables);
        } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    }
    try l.bodies.put(l.gpa, try ca.dupe(u8, id), text);
    return arena.dupe(u8, text);
}

/// `body_hash` of `id`, loading the body if needed (workflow replay keys).
pub fn bodyHash(l: *PromptLibrary, id: []const u8) !u64 {
    var scratch: std.heap.ArenaAllocator = .init(l.gpa);
    defer scratch.deinit();
    _ = try l.body(id, scratch.allocator());
    return l.get(id).?.body_hash;
}

/// Renders a body with its entry's declarations.
pub fn render(arena: Allocator, body_text: []const u8, decls: []const VarDecl, values: []const template.Var, ctx: template.RenderCtx) !template.Rendered {
    return template.render(arena, body_text, decls, values, ctx);
}

/// What inserting entry `id` puts in a composer: skills as `/name args`
/// (E10 runs them; never inlined), prompts rendered with `values`.
pub const Insertion = union(enum) {
    text: template.Rendered,
    command: []const u8,
};

pub fn insertion(l: *PromptLibrary, arena: Allocator, id: []const u8, values: []const template.Var, ctx: template.RenderCtx, args: []const u8) !Insertion {
    const e = l.get(id) orelse return error.UnknownEntry;
    if (e.source == .skill) {
        const cmd = if (args.len == 0) id else try std.fmt.allocPrint(arena, "{s} {s}", .{ id, args });
        return .{ .command = try arena.dupe(u8, cmd) };
    }
    const b = try l.body(id, arena);
    return .{ .text = try render(arena, b, e.variables, values, ctx) };
}

// --- Search ---

/// The best `k` entries for `q` (all entries by use and id when `q` is
/// empty), best first.
pub fn search(l: *PromptLibrary, q: []const u8, k: u32, out: *std.ArrayList(Hit), gpa: Allocator) !void {
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    out.clearRetainingCapacity();
    for (l.entries.items) |*e| {
        const base = if (q.len == 0) 0 else bestScore(q, e) orelse continue;
        const uses = l.usage.get(e.id) orelse 0;
        const boost: i32 = @intCast(@min(uses, 50) * 4);
        const prec: i32 = switch (e.source) {
            .project => 3,
            .user => 2,
            .builtin => 1,
            .skill => 0,
        };
        try out.append(gpa, .{ .entry = e, .score = base + boost + prec });
    }
    std.mem.sort(Hit, out.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.lessThan(u8, a.entry.id, b.entry.id);
        }
    }.lt);
    if (out.items.len > k) out.shrinkRetainingCapacity(k);
}

fn bestScore(q: []const u8, e: *const Entry) ?i32 {
    var best: ?i32 = null;
    const fields = [_]struct { s: []const u8, w: i32 }{
        .{ .s = e.id, .w = 3 },
        .{ .s = e.title, .w = 3 },
        .{ .s = e.description, .w = 1 },
    };
    for (fields) |f| if (fuzzyScore(q, f.s)) |sc| {
        const v = sc * f.w;
        if (best == null or v > best.?) best = v;
    };
    for (e.tags) |t| if (fuzzyScore(q, t)) |sc| {
        const v = sc * 2;
        if (best == null or v > best.?) best = v;
    };
    return best;
}

/// Subsequence match, case-insensitive (the E04 quick-pick scoring:
/// matched characters, word-start and consecutive bonuses, gap
/// penalties); null when `q` is not a subsequence of `cand`.
pub fn fuzzyScore(q: []const u8, cand: []const u8) ?i32 {
    if (q.len == 0) return 0;
    if (q.len > cand.len) return null;
    var score: i32 = 0;
    var qi: usize = 0;
    var prev_match: ?usize = null;
    for (cand, 0..) |c, i| {
        if (qi == q.len) break;
        if (std.ascii.toLower(c) != std.ascii.toLower(q[qi])) continue;
        score += 16;
        if (i == 0 or isSep(cand[i - 1]) or (std.ascii.isUpper(c) and std.ascii.isLower(cand[i - 1]))) score += 8;
        if (prev_match) |p| {
            if (p + 1 == i) score += 6 else score -= @intCast(@min(3 + (i - p - 1), 12));
        } else if (i > 0) score -= @intCast(@min(i, 8));
        if (c == q[qi]) score += 1;
        prev_match = i;
        qi += 1;
    }
    if (qi < q.len) return null;
    return score - @as(i32, @intCast(@min(cand.len, 64) / 8));
}

fn isSep(c: u8) bool {
    return switch (c) {
        ' ', '_', '-', '.', ':', '/', '\\' => true,
        else => false,
    };
}

// --- Usage ---

/// Counts a use of `id` (picker insert, workflow reference) and saves.
pub fn noteUse(l: *PromptLibrary, id: []const u8) void {
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    const gop = l.usage.getOrPut(l.gpa, id) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = l.cache_arena.allocator().dupe(u8, id) catch {
            l.usage.removeByPtr(gop.key_ptr);
            return;
        };
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
    l.saveUsageLocked();
}

const UsageFile = struct { uses: []const struct { id: []const u8, n: u32 } = &.{} };

fn loadUsage(l: *PromptLibrary) void {
    const dir = l.dirs.state orelse return;
    const ca = l.cache_arena.allocator();
    const bytes = dir.readFileAllocOptions(l.io, usage_file, ca, .limited(1 << 20), .of(u8), 0) catch return;
    const f = std.zon.parse.fromSliceAlloc(UsageFile, ca, bytes, null, .{}) catch return;
    for (f.uses) |u| l.usage.put(l.gpa, u.id, u.n) catch return;
}

fn saveUsageLocked(l: *PromptLibrary) void {
    const dir = l.dirs.state orelse return;
    var w: std.Io.Writer.Allocating = .init(l.gpa);
    defer w.deinit();
    w.writer.writeAll(".{ .uses = .{\n") catch return;
    var it = l.usage.iterator();
    while (it.next()) |kv| {
        w.writer.writeAll("    .{ .id = ") catch return;
        std.zon.stringify.serialize(kv.key_ptr.*, .{}, &w.writer) catch return;
        w.writer.print(", .n = {d} }},\n", .{kv.value_ptr.*}) catch return;
    }
    w.writer.writeAll("} }\n") catch return;
    var af = dir.createFileAtomic(l.io, usage_file, .{ .replace = true }) catch return;
    defer af.deinit(l.io);
    af.file.writeStreamingAll(l.io, w.written()) catch return;
    af.replace(l.io) catch return;
}

// --- Create ---

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128 or id[0] == '/' or id[id.len - 1] == '/') return false;
    var it = std.mem.splitScalar(u8, id, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or seg[0] == '.') return false;
        for (seg) |c| switch (c) {
            'a'...'z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        };
    }
    return true;
}

/// The Markdown file for `e`.
pub fn formatEntry(a: Allocator, e: NewEntry) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    const out = &w.writer;
    try out.writeAll("---\ntitle: ");
    try yamlScalar(out, e.title);
    if (e.description.len > 0) {
        try out.writeAll("\ndescription: ");
        try yamlScalar(out, e.description);
    }
    if (e.tags.len > 0) {
        try out.writeAll("\ntags: [");
        for (e.tags, 0..) |t, i| {
            if (i > 0) try out.writeAll(", ");
            try yamlScalar(out, t);
        }
        try out.writeAll("]");
    }
    if (e.variables.len > 0) {
        try out.writeAll("\nvariables:");
        for (e.variables) |v| {
            try out.writeAll("\n  - {name: ");
            try yamlScalar(out, v.name);
            try out.print(", type: {t}", .{v.kind});
            if (v.options.len > 0) {
                try out.writeAll(", options: [");
                for (v.options, 0..) |o, i| {
                    if (i > 0) try out.writeAll(", ");
                    try yamlScalar(out, o);
                }
                try out.writeAll("]");
            }
            if (v.default) |d| {
                try out.writeAll(", default: ");
                try yamlScalar(out, d);
            }
            if (v.required) try out.writeAll(", required: true");
            try out.writeAll("}");
        }
    }
    try out.writeAll("\n---\n");
    try out.writeAll(e.body);
    if (e.body.len == 0 or e.body[e.body.len - 1] != '\n') try out.writeAll("\n");
    return w.written();
}

fn yamlScalar(w: *std.Io.Writer, s: []const u8) !void {
    var plain = s.len > 0 and std.ascii.isAlphanumeric(s[0]);
    for (s) |c| switch (c) {
        ':', '#', ',', '[', ']', '{', '}', '"', '\'', '\n', '\r', '\t', '\\' => plain = false,
        else => {},
    };
    if (plain and s[s.len - 1] != ' ') return w.writeAll(s);
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

pub const Created = struct { id: []const u8, path: []const u8, changeset: ?u64 };

/// Writes entry `e` in `scope` through the write port. The entry appears
/// once the file exists (`reload`, or the app's file events).
pub fn create(l: *PromptLibrary, arena: Allocator, scope: Scope, e: NewEntry) !Created {
    if (!validId(e.id)) return error.InvalidId;
    const port = l.writer orelse return error.NoWritePort;
    if (l.get(e.id)) |old| if (old.source == .project or (old.source == .user and scope == .user)) return error.AlreadyExists;
    const rel = try std.fmt.allocPrint(arena, "{s}.md", .{e.id});
    const bytes = try formatEntry(arena, e);
    const cs = try port.write(port.ctx, scope, rel, bytes);
    return .{ .id = e.id, .path = rel, .changeset = cs };
}

/// A `docs.shortcuts.TemplateLookup` source: the body of `doc/<id>` when a
/// project or user entry overrides the built-in.
pub fn overrideBody(l: *PromptLibrary, key: []const u8) ?[]const u8 {
    const e = l.get(key) orelse return null;
    if (e.source != .project and e.source != .user) return null;
    _ = l.body(key, l.cache_arena.allocator()) catch return null;
    l.mutex.lockUncancelable(l.io);
    defer l.mutex.unlock(l.io);
    return l.bodies.get(key);
}
