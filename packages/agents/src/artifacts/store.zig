//! The artifact store (E13.F07.S01.T01): documents, tables, charts,
//! diagrams, images and code that agents produce beside the conversation,
//! with immutable versions and provenance.
//!
//! Layout under the store directory (`.zigguro/artifacts`):
//!   <id>/meta.zon   {id, kind, title, created, run, project, versions: [...]}
//!   <id>/v<N>.<ext> one file per version, never rewritten
//! A version identical to the latest one (BLAKE3) isn't stored again.
//! Files over `link_threshold` imported from program outputs are linked
//! (their path recorded) rather than copied.

const std = @import("std");
const zg_ai = @import("zg_ai");
const kinds = @import("kinds.zig");
const runs = @import("../runs/root.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Clock = zg_ai.ratelimit.Clock;
const RunId = runs.RunId;

pub const ArtifactKind = kinds.ArtifactKind;

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub const ArtifactId = struct {
    n: u64,

    pub const text_len = 15;

    /// "A-" and 13 Crockford base32 digits.
    pub fn text(id: ArtifactId) [text_len]u8 {
        var out: [text_len]u8 = undefined;
        out[0] = 'A';
        out[1] = '-';
        var v = id.n;
        var i: usize = text_len;
        while (i > 2) {
            i -= 1;
            out[i] = crockford[@intCast(v & 31)];
            v >>= 5;
        }
        return out;
    }

    pub fn format(id: ArtifactId, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(&id.text());
    }

    /// Parses the text form (case-insensitive; `I`/`L` read as 1, `O` as 0).
    pub fn parse(s: []const u8) ?ArtifactId {
        if (s.len != text_len or (s[0] != 'A' and s[0] != 'a') or s[1] != '-') return null;
        var v: u64 = 0;
        for (s[2..], 0..) |c, i| {
            const d: u64 = switch (std.ascii.toUpper(c)) {
                '0', 'O' => 0,
                '1', 'I', 'L' => 1,
                else => |u| @intCast(std.mem.indexOfScalar(u8, crockford, u) orelse return null),
            };
            // The first digit carries only 4 of 65 bits.
            if (i == 0 and d > 15) return null;
            v = v << 5 | d;
        }
        return .{ .n = v };
    }

    pub fn eql(a: ArtifactId, b: ArtifactId) bool {
        return a.n == b.n;
    }
};

/// Who produced a version.
pub const Provenance = struct {
    run: ?RunId = null,
    session: ?[]const u8 = null,
    tool_call: ?[]const u8 = null,
};

pub const Version = struct {
    n: u32,
    created: i64,
    size: u64,
    /// Hex BLAKE3 of the content.
    blake3: []const u8,
    ext: []const u8,
    mime: []const u8,
    note: ?[]const u8 = null,
    run: ?[]const u8 = null,
    session: ?[]const u8 = null,
    tool_call: ?[]const u8 = null,
    /// The file this version points at instead of a copy.
    link: ?[]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,
};

/// An artifact as stored in `meta.zon`.
pub const Artifact = struct {
    id: []const u8,
    kind: ArtifactKind,
    title: []const u8,
    created: i64,
    /// The producing run's id (text form).
    run: ?[]const u8 = null,
    source_lang: ?[]const u8 = null,
    /// The E13.F09 project slug.
    project: ?[]const u8 = null,
    versions: []const Version,

    pub fn latest(a: *const Artifact) *const Version {
        return &a.versions[a.versions.len - 1];
    }

    pub fn version(a: *const Artifact, n: ?u32) ?*const Version {
        const want = n orelse return a.latest();
        for (a.versions) |*v| if (v.n == want) return v;
        return null;
    }

    pub fn artifactId(a: *const Artifact) ArtifactId {
        return ArtifactId.parse(a.id).?;
    }
};

pub const NewArtifact = struct {
    kind: ArtifactKind,
    title: []const u8,
    content: []const u8,
    mime: ?[]const u8 = null,
    run: ?RunId = null,
    source_lang: ?[]const u8 = null,
    session: ?[]const u8 = null,
    tool_call: ?[]const u8 = null,
    /// The run's project, or the active one when a person creates it.
    project: ?[]const u8 = null,
};

pub const UpdateOpts = struct {
    note: ?[]const u8 = null,
    prov: Provenance = .{},
};

pub const ListFilter = struct {
    run: ?RunId = null,
    kind: ?ArtifactKind = null,
    project: ?ProjectMatch = null,
};

/// A project filter chip: one project, or artifacts outside any.
pub const ProjectMatch = union(enum) {
    slug: []const u8,
    none,

    pub fn matches(m: ProjectMatch, project: ?[]const u8) bool {
        return switch (m) {
            .none => project == null,
            .slug => |x| if (project) |p| std.mem.eql(u8, p, x) else false,
        };
    }
};

pub const Content = struct {
    kind: ArtifactKind,
    version: u32,
    versions: u32,
    ext: []const u8,
    mime: []const u8,
    bytes: []const u8,
    link: ?[]const u8 = null,
};

/// Records an artifact among a run's outputs (F01's registry).
pub const OutputPort = struct {
    ctx: *anyopaque,
    add: *const fn (ctx: *anyopaque, run: RunId, artifact: []const u8) void,

    /// Adds outputs to `reg` (`Update.output`).
    pub fn registry(reg: *runs.RunRegistry) OutputPort {
        return .{ .ctx = reg, .add = struct {
            fn add(ctx: *anyopaque, run: RunId, artifact: []const u8) void {
                const r: *runs.RunRegistry = @ptrCast(@alignCast(ctx));
                r.update(run, .{ .output = .{ .artifact = artifact } }) catch {};
            }
        }.add };
    }
};

pub const Options = struct {
    clock: Clock = .real,
    validators: kinds.Validators = .{},
    outputs: ?OutputPort = null,
    /// Imported files larger than this are linked, not copied.
    link_threshold: u64 = 100 << 20,
};

const Entry = struct {
    arena: std.heap.ArenaAllocator,
    meta: Artifact,
};

pub const ArtifactStore = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    o: Options,
    mutex: Io.Mutex = .init,
    entries: std.AutoArrayHashMapUnmanaged(u64, *Entry) = .empty,
    /// Bumped on every change (views poll it).
    revision: std.atomic.Value(u64) = .init(0),
    /// Artifact folders whose meta.zon couldn't be read at open.
    load_errors: u32 = 0,
    prng: std.Random.DefaultPrng,
    last_id: u64 = 0,

    /// Opens the store in `dir` (`.zigguro/artifacts`, opened with
    /// `.iterate = true`), loading every artifact's metadata. `dir` stays
    /// the caller's.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, o: Options) !*ArtifactStore {
        const s = try gpa.create(ArtifactStore);
        errdefer gpa.destroy(s);
        var seed: [8]u8 = undefined;
        io.random(&seed);
        s.* = .{ .gpa = gpa, .io = io, .dir = dir, .o = o, .prng = .init(std.mem.readInt(u64, &seed, .little)) };
        errdefer s.close();
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .directory) continue;
            const id = ArtifactId.parse(e.name) orelse continue;
            s.last_id = @max(s.last_id, id.n);
            s.loadOne(id) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => s.load_errors += 1,
            };
        }
        return s;
    }

    pub fn close(s: *ArtifactStore) void {
        for (s.entries.values()) |e| {
            e.arena.deinit();
            s.gpa.destroy(e);
        }
        s.entries.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn loadOne(s: *ArtifactStore, id: ArtifactId) !void {
        const name = id.text();
        var sub = try s.dir.openDir(s.io, &name, .{});
        defer sub.close(s.io);
        const e = try s.gpa.create(Entry);
        e.* = .{ .arena = .init(s.gpa), .meta = undefined };
        errdefer {
            e.arena.deinit();
            s.gpa.destroy(e);
        }
        const a = e.arena.allocator();
        const src = try sub.readFileAllocOptions(s.io, "meta.zon", a, .limited(16 << 20), .of(u8), 0);
        e.meta = try std.zon.parse.fromSliceAlloc(Artifact, a, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false });
        if (e.meta.versions.len == 0 or !std.mem.eql(u8, e.meta.id, &name)) return error.InvalidMeta;
        try s.entries.put(s.gpa, id.n, e);
    }

    fn now(s: *ArtifactStore) i64 {
        return s.o.clock.now(s.io);
    }

    /// Milliseconds and 16 random bits, kept increasing within a store
    /// so ids sort in creation order.
    fn newId(s: *ArtifactStore) ArtifactId {
        const ms: u64 = @intCast(@max(0, s.now()));
        var n = (ms << 16) | s.prng.random().int(u16);
        if (n <= s.last_id) n = s.last_id + 1;
        while (s.entries.contains(n)) n +%= 1;
        s.last_id = n;
        return .{ .n = n };
    }

    /// Creates an artifact with its first version (`error.Invalid` when
    /// the content fails its kind's validation).
    pub fn create(s: *ArtifactStore, a: NewArtifact) !ArtifactId {
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        var msg: []const u8 = "";
        return s.createChecked(scratch.allocator(), a, &msg);
    }

    /// `create`, with the validation message of `error.Invalid` in
    /// `invalid` (allocated in `arena`).
    pub fn createChecked(s: *ArtifactStore, arena: Allocator, a: NewArtifact, invalid: *[]const u8) !ArtifactId {
        const checked = switch (try kinds.validate(arena, a.kind, a.content, a.source_lang, s.o.validators)) {
            .ok => |c| c,
            .invalid => |i| {
                invalid.* = i.message;
                return error.Invalid;
            },
        };
        return s.insert(a, checked, null);
    }

    fn insert(s: *ArtifactStore, a: NewArtifact, checked: kinds.Checked, link: ?[]const u8) !ArtifactId {
        const e = try s.gpa.create(Entry);
        e.* = .{ .arena = .init(s.gpa), .meta = undefined };
        var owned = false;
        defer if (!owned) {
            e.arena.deinit();
            s.gpa.destroy(e);
        };
        const ar = e.arena.allocator();
        const t = s.now();
        const run_text: ?[]const u8 = if (a.run) |r| try ar.dupe(u8, &r.text()) else null;

        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const id = s.newId();
        const id_text = id.text();
        const v = try s.versionOf(ar, 1, t, a.content, checked, link, null, .{ .run = a.run, .session = a.session, .tool_call = a.tool_call });
        const vs = try ar.alloc(Version, 1);
        vs[0] = v;
        e.meta = .{
            .id = try ar.dupe(u8, &id_text),
            .kind = a.kind,
            .title = try ar.dupe(u8, a.title),
            .created = t,
            .run = run_text,
            .source_lang = if (a.source_lang) |l| try ar.dupe(u8, l) else null,
            .project = if (a.project) |x| try ar.dupe(u8, x) else null,
            .versions = vs,
        };
        try s.dir.createDirPath(s.io, &id_text);
        var sub = try s.dir.openDir(s.io, &id_text, .{});
        defer sub.close(s.io);
        if (link == null) try writeAtomic(s.io, sub, try versionName(ar, v), a.content);
        try s.writeMeta(sub, &e.meta);
        try s.entries.put(s.gpa, id.n, e);
        owned = true;
        _ = s.revision.fetchAdd(1, .release);
        if (a.run) |r| if (s.o.outputs) |o| o.add(o.ctx, r, e.meta.id);
        return id;
    }

    fn versionOf(s: *ArtifactStore, ar: Allocator, n: u32, t: i64, content: []const u8, c: kinds.Checked, link: ?[]const u8, note: ?[]const u8, p: Provenance) !Version {
        _ = s;
        var h: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(content, &h, .{});
        return .{
            .n = n,
            .created = t,
            .size = content.len,
            .blake3 = try ar.dupe(u8, &std.fmt.bytesToHex(h, .lower)),
            .ext = try ar.dupe(u8, c.ext),
            .mime = try ar.dupe(u8, c.mime),
            .note = if (note) |x| try ar.dupe(u8, x) else null,
            .run = if (p.run) |r| try ar.dupe(u8, &r.text()) else null,
            .session = if (p.session) |x| try ar.dupe(u8, x) else null,
            .tool_call = if (p.tool_call) |x| try ar.dupe(u8, x) else null,
            .link = if (link) |x| try ar.dupe(u8, x) else null,
            .width = if (c.image) |i| i.w else 0,
            .height = if (c.image) |i| i.h else 0,
        };
    }

    /// Adds a version with `content`; returns its number (the latest
    /// one's when `content` is identical to it).
    pub fn update(s: *ArtifactStore, id: ArtifactId, content: []const u8, note: ?[]const u8) !u32 {
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        var msg: []const u8 = "";
        return s.updateChecked(scratch.allocator(), id, content, .{ .note = note }, &msg);
    }

    pub fn updateChecked(s: *ArtifactStore, arena: Allocator, id: ArtifactId, content: []const u8, uo: UpdateOpts, invalid: *[]const u8) !u32 {
        const kind, const lang = blk: {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            const e = s.entries.get(id.n) orelse return error.UnknownArtifact;
            break :blk .{ e.meta.kind, if (e.meta.source_lang) |l| try arena.dupe(u8, l) else null };
        };
        const checked = switch (try kinds.validate(arena, kind, content, lang, s.o.validators)) {
            .ok => |c| c,
            .invalid => |i| {
                invalid.* = i.message;
                return error.Invalid;
            },
        };
        var h: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(content, &h, .{});
        const hex = std.fmt.bytesToHex(h, .lower);

        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const e = s.entries.get(id.n) orelse return error.UnknownArtifact;
        const last = e.meta.latest();
        if (last.link == null and std.mem.eql(u8, last.blake3, &hex)) return last.n;
        // A fresh arena holds the new metadata; the old one goes once
        // the files are written.
        var next: std.heap.ArenaAllocator = .init(s.gpa);
        var keep = false;
        defer if (!keep) next.deinit();
        const ar = next.allocator();
        var meta = e.meta;
        meta.id = try ar.dupe(u8, meta.id);
        meta.title = try ar.dupe(u8, meta.title);
        meta.run = if (meta.run) |r| try ar.dupe(u8, r) else null;
        meta.source_lang = if (meta.source_lang) |l| try ar.dupe(u8, l) else null;
        meta.project = if (meta.project) |x| try ar.dupe(u8, x) else null;
        const vs = try ar.alloc(Version, meta.versions.len + 1);
        for (meta.versions, vs[0..meta.versions.len]) |v, *o| o.* = try dupeVersion(ar, v);
        vs[meta.versions.len] = try s.versionOf(ar, last.n + 1, s.now(), content, checked, null, uo.note, uo.prov);
        meta.versions = vs;
        var sub = try s.dir.openDir(s.io, meta.id, .{});
        defer sub.close(s.io);
        try writeAtomic(s.io, sub, try versionName(ar, vs[vs.len - 1]), content);
        try s.writeMeta(sub, &meta);
        e.arena.deinit();
        e.arena = next;
        e.meta = meta;
        keep = true;
        _ = s.revision.fetchAdd(1, .release);
        return vs[vs.len - 1].n;
    }

    fn writeMeta(s: *ArtifactStore, sub: Io.Dir, meta: *const Artifact) !void {
        var out: Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        std.zon.stringify.serialize(meta.*, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
        try out.writer.writeByte('\n');
        try writeAtomic(s.io, sub, "meta.zon", out.written());
    }

    /// A deep copy of artifact `id`'s metadata, in `a`.
    pub fn get(s: *ArtifactStore, id: ArtifactId, a: Allocator) !?Artifact {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const e = s.entries.get(id.n) orelse return null;
        return try dupeArtifact(a, e.meta);
    }

    /// Reads version `version` (the latest when null) of `id` into `a`.
    /// A linked version's bytes are read from its file.
    pub fn read(s: *ArtifactStore, id: ArtifactId, version: ?u32, a: Allocator) !Content {
        const meta = (try s.get(id, a)) orelse return error.UnknownArtifact;
        const v = meta.version(version) orelse return error.UnknownVersion;
        const bytes = if (v.link) |l|
            try Io.Dir.cwd().readFileAlloc(s.io, l, a, .limited(std.math.maxInt(usize)))
        else blk: {
            var sub = try s.dir.openDir(s.io, meta.id, .{});
            defer sub.close(s.io);
            break :blk try sub.readFileAlloc(s.io, try versionName(a, v.*), a, .limited(kinds.max_binary + 1));
        };
        return .{ .kind = meta.kind, .version = v.n, .versions = @intCast(meta.versions.len), .ext = v.ext, .mime = v.mime, .bytes = bytes, .link = v.link };
    }

    /// The artifacts matching `filter`, oldest first, copied into `a`
    /// (pass an arena).
    pub fn list(s: *ArtifactStore, filter: ListFilter, out: *std.ArrayList(Artifact), a: Allocator) !void {
        const run_text: ?[26]u8 = if (filter.run) |r| r.text() else null;
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const start = out.items.len;
        for (s.entries.values()) |e| {
            if (filter.kind) |k| if (e.meta.kind != k) continue;
            if (filter.project) |m| if (!m.matches(e.meta.project)) continue;
            if (run_text) |rt| if (e.meta.run == null or !std.mem.eql(u8, e.meta.run.?, &rt)) continue;
            try out.append(a, try dupeArtifact(a, e.meta));
        }
        std.sort.pdq(Artifact, out.items[start..], {}, struct {
            fn lt(_: void, x: Artifact, y: Artifact) bool {
                return ArtifactId.parse(x.id).?.n < ArtifactId.parse(y.id).?.n;
            }
        }.lt);
    }

    /// See `save.saveToWorkspace`.
    pub const saveToWorkspace = @import("save.zig").saveToWorkspace;

    pub const ImportOpts = struct {
        run: ?RunId = null,
        title: ?[]const u8 = null,
        kind: ?ArtifactKind = null,
        session: ?[]const u8 = null,
        tool_call: ?[]const u8 = null,
        project: ?[]const u8 = null,
    };

    /// Creates an artifact from a file (F06 program outputs). The kind
    /// comes from the extension, falling back to text; files over
    /// `link_threshold` are linked by path.
    pub fn importFile(s: *ArtifactStore, path: []const u8, run: ?RunId) !ArtifactId {
        return s.importFileWith(path, .{ .run = run });
    }

    pub fn importFileWith(s: *ArtifactStore, path: []const u8, io_: ImportOpts) !ArtifactId {
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const cwd = Io.Dir.cwd();
        const st = try cwd.statFile(s.io, path, .{});
        const title = io_.title orelse std.fs.path.basename(path);
        var na: NewArtifact = .{ .kind = io_.kind orelse kinds.kindForPath(path), .title = title, .content = "", .run = io_.run, .session = io_.session, .tool_call = io_.tool_call, .project = io_.project };
        if (st.size > s.o.link_threshold) {
            const ext = std.fs.path.extension(path);
            return s.insert(na, .{ .ext = if (ext.len > 1) ext[1..] else "bin", .mime = "application/octet-stream" }, path);
        }
        na.content = try cwd.readFileAlloc(s.io, path, a, .limited(kinds.max_binary + 1));
        if (na.kind == .code) na.source_lang = langForPath(path);
        var msg: []const u8 = "";
        return s.createChecked(a, na, &msg) catch |e| switch (e) {
            error.Invalid => {
                // A file whose extension promised more than it holds is
                // kept as plain text when it can be.
                if (na.kind == .text or na.kind == .image) return e;
                na.kind = .text;
                na.source_lang = null;
                return s.createChecked(a, na, &msg);
            },
            else => return e,
        };
    }
};

fn langForPath(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    return if (ext.len > 1) ext[1..] else null;
}

pub fn versionName(a: Allocator, v: Version) ![]const u8 {
    return std.fmt.allocPrint(a, "v{d}.{s}", .{ v.n, v.ext });
}

fn dupeOpt(a: Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |x| try a.dupe(u8, x) else null;
}

fn dupeVersion(a: Allocator, v: Version) !Version {
    var o = v;
    o.blake3 = try a.dupe(u8, v.blake3);
    o.ext = try a.dupe(u8, v.ext);
    o.mime = try a.dupe(u8, v.mime);
    o.note = try dupeOpt(a, v.note);
    o.run = try dupeOpt(a, v.run);
    o.session = try dupeOpt(a, v.session);
    o.tool_call = try dupeOpt(a, v.tool_call);
    o.link = try dupeOpt(a, v.link);
    return o;
}

pub fn dupeArtifact(a: Allocator, m: Artifact) !Artifact {
    var o = m;
    o.id = try a.dupe(u8, m.id);
    o.title = try a.dupe(u8, m.title);
    o.run = try dupeOpt(a, m.run);
    o.source_lang = try dupeOpt(a, m.source_lang);
    o.project = try dupeOpt(a, m.project);
    const vs = try a.alloc(Version, m.versions.len);
    for (m.versions, vs) |v, *x| x.* = try dupeVersion(a, v);
    o.versions = vs;
    return o;
}

fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var af = try dir.createFileAtomic(io, name, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}
