//! NoteIndex tests (E08.F06.S01.T02).

const std = @import("std");
const ni = @import("note_index.zig");
const mentions = @import("mentions.zig");
const vault_mod = @import("../vault/vault.zig");
const note = @import("../vault/note.zig");
const gen = @import("../testing/gen.zig");
const testdata = @import("../testing/testdata.zig");

const testing = std.testing;
const FileId = note.FileId;
const NoteIndex = ni.NoteIndex;

fn fid(i: u32) FileId {
    return .{ .index = i, .gen = 0 };
}

const whole_root: vault_mod.Vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "", .config = .{} };

/// A vault of in-memory notes keyed by path, fed to an index.
const Fixture = struct {
    ix: *NoteIndex,
    paths: std.ArrayList([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,

    fn init() !Fixture {
        return .{ .ix = try NoteIndex.init(testing.allocator, testing.io, &.{whole_root}), .arena = .init(testing.allocator) };
    }

    fn deinit(f: *Fixture) void {
        f.ix.deinit();
        f.paths.deinit(testing.allocator);
        f.arena.deinit();
    }

    fn idOf(f: *Fixture, path: []const u8) FileId {
        for (f.paths.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) return fid(@intCast(i));
        unreachable;
    }

    fn add(f: *Fixture, path: []const u8, bytes: []const u8) !FileId {
        const id = fid(@intCast(f.paths.items.len));
        try f.paths.append(testing.allocator, try f.arena.allocator().dupe(u8, path));
        if (vault_mod.isMarkdownName(path)) try f.ix.indexNote(id, .of(0), path, bytes) else try f.ix.setAttachment(id, .of(0), path);
        return id;
    }
};

fn expectResolved(v: *const ni.IndexView, f: *Fixture, from: []const u8, link_i: usize, want: []const u8) !void {
    const id = f.idOf(from);
    const r = v.outgoing(id)[link_i];
    const meta = v.note(id).?;
    errdefer std.debug.print("{s} link {d} ({s}): got {t} {?s} ambiguous={}\n", .{ from, link_i, meta.links[link_i].target, r.kind, v.pathOf(r.id), r.ambiguous });
    if (std.mem.eql(u8, want, "unresolved")) return testing.expectEqual(ni.ResolvedKind.unresolved, r.kind);
    if (std.mem.eql(u8, want, "self")) return testing.expectEqual(ni.ResolvedKind.self, r.kind);
    const amb = std.mem.startsWith(u8, want, "ambiguous:");
    const path = if (amb) want["ambiguous:".len..] else want;
    try testing.expect(r.kind == .note or r.kind == .attachment);
    try testing.expectEqualStrings(path, v.pathOf(r.id).?);
    try testing.expectEqual(amb, r.ambiguous);
}

test "note_index: obsidian compat fixture resolves as expected" {
    const io = testing.io;
    var dir = try testdata.openDir("testdata/vault_compat");
    defer dir.close(io);
    var f = try Fixture.init();
    defer f.deinit();
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(testing.allocator);
    while (try walker.next(io)) |e| {
        if (e.kind != .file or std.mem.eql(u8, e.path, "expected.txt")) continue;
        try files.append(testing.allocator, try f.arena.allocator().dupe(u8, e.path));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (files.items) |p| {
        const bytes = try dir.readFileAlloc(io, p, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        _ = try f.add(p, bytes);
    }
    try f.ix.commit();
    const v = try f.ix.reader();
    defer v.release();
    const expected = try dir.readFileAlloc(io, "expected.txt", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(expected);
    var lines = std.mem.tokenizeScalar(u8, expected, '\n');
    var per_source: std.StringHashMapUnmanaged(usize) = .empty;
    defer per_source.deinit(testing.allocator);
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        // `source|link as written|expected`; the link may hold `|`.
        const first = std.mem.indexOfScalar(u8, line, '|').?;
        const last = std.mem.lastIndexOfScalar(u8, line, '|').?;
        const src = line[0..first];
        const link_text = line[first + 1 .. last];
        const want = line[last + 1 ..];
        const gop = try per_source.getOrPut(testing.allocator, src);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        const i = gop.value_ptr.*;
        gop.value_ptr.* += 1;
        // The fixture writes one link per list item, so the n-th line of
        // a source is its n-th link; check the text to be sure.
        const meta = v.note(f.idOf(src)).?;
        const bytes = try dir.readFileAlloc(io, src, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        try testing.expectEqualStrings(link_text, bytes[meta.links[i].src[0]..meta.links[i].src[1]]);
        try expectResolved(v, &f, src, i, want);
        checked += 1;
    }
    try testing.expect(checked >= 100);
}

test "note_index: resolution table" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.add("a/Same.md", "x");
    _ = try f.add("b/Same.md", "x");
    _ = try f.add("a/From.md", "[[Same]] [[b/Same]] [[Same.md]] [[pic.png]] [[Nick]] [[#H]] [[Nope]]");
    _ = try f.add("c/pic.png", "");
    _ = try f.add("Aliased.md", "---\naliases: [Nick]\n---\n");
    try f.ix.commit();
    const v = try f.ix.reader();
    defer v.release();
    try expectResolved(v, &f, "a/From.md", 0, "ambiguous:a/Same.md");
    try expectResolved(v, &f, "a/From.md", 1, "b/Same.md");
    try expectResolved(v, &f, "a/From.md", 2, "ambiguous:a/Same.md");
    try expectResolved(v, &f, "a/From.md", 3, "c/pic.png");
    try expectResolved(v, &f, "a/From.md", 4, "Aliased.md");
    try expectResolved(v, &f, "a/From.md", 5, "self");
    try expectResolved(v, &f, "a/From.md", 6, "unresolved");
    // The view's own resolver agrees and lists candidates.
    var cands: std.ArrayList(FileId) = .empty;
    defer cands.deinit(testing.allocator);
    const r = try v.resolve(testing.allocator, f.idOf("a/From.md"), "same", .wiki, &cands);
    try testing.expect(r.ambiguous);
    try testing.expectEqual(@as(usize, 2), cands.items.len);
    // Unresolved targets are listed with their sources.
    try testing.expectEqual(@as(usize, 1), v.unresolved().len);
    try testing.expectEqualStrings("Nope", v.unresolved()[0].target);
    // Backlinks.
    try testing.expectEqual(@as(usize, 2), v.backlinks(f.idOf("a/Same.md")).len);
    try testing.expectEqual(@as(usize, 1), v.backlinks(f.idOf("c/pic.png")).len);
}

test "note_index: adding, removing and renaming re-resolve only affected links" {
    var f = try Fixture.init();
    defer f.deinit();
    // 50 notes link to `Target`, 50 to `Other`.
    var buf: [64]u8 = undefined;
    for (0..100) |i| {
        const p = try std.fmt.bufPrint(&buf, "src/s{d}.md", .{i});
        _ = try f.add(p, if (i < 50) "see [[Target]]" else "see [[Other]]");
    }
    try f.ix.commit();
    {
        const v = try f.ix.reader();
        defer v.release();
        try testing.expectEqual(@as(usize, 2), v.unresolved().len);
    }
    const before = f.ix.resolutionCount();
    const target = try f.add("Target.md", "# Target");
    // The new note's own (zero) links plus the 50 that name it.
    try testing.expectEqual(@as(u64, 50), f.ix.resolutionCount() - before);
    try f.ix.commit();
    {
        const v = try f.ix.reader();
        defer v.release();
        try testing.expectEqual(@as(usize, 50), v.backlinks(target).len);
        try testing.expectEqual(@as(usize, 1), v.unresolved().len);
    }
    // Rename Target.md to Renamed.md (same id): its 50 sources re-resolve
    // (now unresolved), nothing else.
    const b2 = f.ix.resolutionCount();
    try f.ix.indexNote(target, .of(0), "Renamed.md", "# Target");
    try testing.expectEqual(@as(u64, 50), f.ix.resolutionCount() - b2);
    // Editing a note's body without touching names re-resolves only its
    // own links.
    const b3 = f.ix.resolutionCount();
    try f.ix.indexNote(f.idOf("src/s0.md"), .of(0), "src/s0.md", "see [[Target]] and [[Other]]");
    try testing.expectEqual(@as(u64, 2), f.ix.resolutionCount() - b3);
    try f.ix.commit();
    const v = try f.ix.reader();
    defer v.release();
    try testing.expectEqual(@as(usize, 0), v.backlinks(target).len);
    try testing.expectEqual(@as(usize, 2), v.unresolved().len);
    // Removing a note.
    try f.ix.removeFile(target);
    try f.ix.commit();
    const v2 = try f.ix.reader();
    defer v2.release();
    try testing.expect(v2.note(target) == null);
    // The old view still sees it.
    try testing.expect(v.note(target) != null);
}

test "note_index: backlinks incremental equals full rebuild" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    const n_notes = 200;
    const opts: gen.Options = .{ .notes = n_notes, .links_per_note = 4, .tags = 30, .folders = 8, .paragraphs = 1 };
    // Current contents and paths; a slot may be absent.
    var paths: [n_notes]?[]const u8 = undefined;
    var bodies: [n_notes][]const u8 = undefined;
    for (0..n_notes) |i| {
        paths[i] = try gen.notePath(a, @intCast(i), opts.folders);
        bodies[i] = try gen.note(a, r, @intCast(i), opts);
    }
    const inc = try NoteIndex.init(testing.allocator, testing.io, &.{whole_root});
    defer inc.deinit();
    for (0..n_notes) |i| try inc.indexNote(fid(@intCast(i)), .of(0), paths[i].?, bodies[i]);
    const iterations = 2000;
    for (0..iterations) |it| {
        const i = r.uintLessThan(usize, n_notes);
        switch (r.uintLessThan(u8, 4)) {
            0 => { // edit the body
                bodies[i] = try gen.note(a, r, @intCast(i), opts);
                if (paths[i]) |p| try inc.indexNote(fid(@intCast(i)), .of(0), p, bodies[i]);
            },
            1 => { // rename
                if (paths[i] != null) {
                    paths[i] = try std.fmt.allocPrint(a, "f{d}/n{d}.md", .{ r.uintLessThan(u32, opts.folders), r.uintLessThan(u32, n_notes) });
                    try inc.indexNote(fid(@intCast(i)), .of(0), paths[i].?, bodies[i]);
                }
            },
            2 => { // remove
                if (paths[i] != null) {
                    paths[i] = null;
                    try inc.removeFile(fid(@intCast(i)));
                }
            },
            else => { // (re)add
                if (paths[i] == null) {
                    paths[i] = try gen.notePath(a, @intCast(i), opts.folders);
                    try inc.indexNote(fid(@intCast(i)), .of(0), paths[i].?, bodies[i]);
                }
            },
        }
        if (it % 100 != 99 and it != iterations - 1) continue;
        // Duplicate paths make a note's resolution depend on insertion
        // order; skip checks while two live notes share a path.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(testing.allocator);
        var dup = false;
        for (paths) |p| if (p) |x| {
            if ((try seen.getOrPut(testing.allocator, x)).found_existing) dup = true;
        };
        if (dup) continue;
        const full = try NoteIndex.init(testing.allocator, testing.io, &.{whole_root});
        defer full.deinit();
        for (0..n_notes) |k| if (paths[k]) |p| try full.indexNote(fid(@intCast(k)), .of(0), p, bodies[k]);
        try inc.commit();
        try full.commit();
        const vi = try inc.reader();
        defer vi.release();
        const vf = try full.reader();
        defer vf.release();
        try testing.expectEqual(vf.noteCount(), vi.noteCount());
        for (0..n_notes) |k| {
            const id = fid(@intCast(k));
            const oi = vi.outgoing(id);
            const of = vf.outgoing(id);
            try testing.expectEqual(of.len, oi.len);
            for (oi, of) |x, y| {
                try testing.expectEqual(y.kind, x.kind);
                try testing.expect(x.id.eql(y.id));
            }
            try testing.expectEqual(vf.backlinks(id).len, vi.backlinks(id).len);
        }
    }
}

test "note_index: unlinked mentions exclude links, code and frontmatter" {
    var f = try Fixture.init();
    defer f.deinit();
    const bodies = [_][2][]const u8{
        .{ "Project Alpha.md", "---\naliases: [PA]\n---\n# Project Alpha\n" },
        .{ "a.md", "---\ntitle: about Project Alpha\n---\nWe discussed project alpha today. [[Project Alpha]] is linked.\n`Project Alpha` in code.\n```\nProject Alpha\n```\nAlso PA and PAx and xPA. %% Project Alpha %%\n" },
        .{ "b.md", "Project Alphabet is not it. Project Alpha, yes.\n" },
    };
    for (bodies) |b| _ = try f.add(b[0], b[1]);
    try f.ix.commit();
    const v = try f.ix.reader();
    defer v.release();
    const Src = struct {
        fn read(ctx: *anyopaque, gpa: std.mem.Allocator, id: FileId, path: []const u8) anyerror!?[]u8 {
            _ = ctx;
            _ = id;
            for (bodies) |b| if (std.mem.eql(u8, b[0], path)) return try gpa.dupe(u8, b[1]);
            return null;
        }
    };
    var out: std.ArrayList(mentions.Mention) = .empty;
    defer out.deinit(testing.allocator);
    var dummy: u8 = 0;
    try mentions.unlinkedMentions(v, testing.allocator, .{ .ctx = &dummy, .read = Src.read }, f.idOf("Project Alpha.md"), &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("project alpha", bodies[1][1][out.items[0].range[0]..out.items[0].range[1]]);
    try testing.expectEqual(@as(u32, 3), out.items[0].line);
    try testing.expectEqualStrings("PA", bodies[1][1][out.items[1].range[0]..out.items[1].range[1]]);
    try testing.expectEqualStrings("Project Alpha", bodies[2][1][out.items[2].range[0]..out.items[2].range[1]]);
}

test "note_index: tags and properties in the view" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.add("1.md", "---\ntags: [Proj/Alpha]\nrating: 3\n---\n#proj/alpha twice #proj/alpha");
    _ = try f.add("2.md", "---\nrating: high\n---\n#PROJ/beta");
    _ = try f.add("3.md", "---\nrating: 5\n---\n#solo");
    try f.ix.commit();
    {
        const v = try f.ix.reader();
        defer v.release();
        const t = v.tagTree();
        try testing.expectEqual(@as(u32, 2), t.find("proj").?.count);
        try testing.expectEqualStrings("Proj", t.find("proj").?.name);
        try testing.expectEqual(@as(u32, 1), t.find("proj/alpha").?.count);
        try testing.expectEqual(note.PropertyType.number, v.propertyType("Rating"));
        try testing.expectEqual(@as(usize, 1), v.properties()[0].conflicts.len);
    }
    try f.ix.setPropertyType("rating", .text);
    try f.ix.commit();
    const v = try f.ix.reader();
    defer v.release();
    try testing.expectEqual(note.PropertyType.text, v.propertyType("rating"));
    try testing.expectEqual(@as(usize, 0), v.properties()[0].conflicts.len);
}

test "note_index: persistence roundtrip and adoption" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.add("A.md", "---\ntitle: The A\ntags: [x]\nwhen: 2024-01-02\n---\n# A\nlinks [[B#Head|b]] ^blk\n- [ ] task");
    _ = try f.add("B.md", "# B\n## Head\n");
    try f.ix.save(tmp.dir, "notes.bin");
    const ix2 = try NoteIndex.init(testing.allocator, io, &.{whole_root});
    defer ix2.deinit();
    try testing.expectEqual(@as(usize, 2), try ix2.load(tmp.dir, "notes.bin"));
    const zg_workspace = @import("zg_workspace");
    // New ids at warm start; matched by path hash.
    try testing.expect(try ix2.adopt(fid(10), zg_workspace.index_plugin.pathHash(.of(0), "A.md")));
    try testing.expect(try ix2.adopt(fid(11), zg_workspace.index_plugin.pathHash(.of(0), "B.md")));
    try testing.expect(!try ix2.adopt(fid(12), zg_workspace.index_plugin.pathHash(.of(0), "C.md")));
    try ix2.commit();
    const v = try ix2.reader();
    defer v.release();
    const m = v.note(fid(10)).?;
    try testing.expectEqualStrings("The A", m.title);
    try testing.expectEqualStrings("b", m.links[0].alias.?);
    try testing.expectEqualStrings("Head", m.links[0].subpath.?.heading[0]);
    try testing.expectEqual(@as(usize, 1), m.tasks.len);
    try testing.expectEqualStrings("blk", m.blocks[0].id);
    try testing.expect(m.prop("when").?.node.value.date.eql(.{ .y = 2024, .m = 1, .d = 2 }));
    try testing.expect(v.outgoing(fid(10))[0].id.eql(fid(11)));
    // A corrupt file loads nothing.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.bin", .data = "ZGNIjunk" });
    try testing.expectEqual(@as(usize, 0), try ix2.load(tmp.dir, "bad.bin"));
}

test "note_index: findByName and plugin wiring" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.add("work/Meeting Notes.md", "# Meeting Notes");
    _ = try f.add("Groceries.md", "---\naliases: [Shopping]\n---\n");
    try f.ix.commit();
    const v = try f.ix.reader();
    defer v.release();
    const hits = try v.findByName(testing.allocator, "mn", 5);
    defer testing.allocator.free(hits);
    try testing.expect(hits.len >= 1);
    try testing.expect(hits[0].id.eql(f.idOf("work/Meeting Notes.md")));
    const hits2 = try v.findByName(testing.allocator, "shop", 5);
    defer testing.allocator.free(hits2);
    try testing.expectEqual(@as(usize, 1), hits2.len);
    const zg_workspace = @import("zg_workspace");
    const p = f.ix.plugin();
    const ref: zg_workspace.index_plugin.FileRef = .{ .id = fid(99), .root = .of(0), .rel = "new.md", .path_hash = 1 };
    try testing.expect(p.wants(p.ctx, &ref, .text));
    const png: zg_workspace.index_plugin.FileRef = .{ .id = fid(98), .root = .of(0), .rel = "x.png", .path_hash = 2 };
    try testing.expect(!p.wants(p.ctx, &png, .text));
    var out: zg_workspace.index_plugin.PluginOutput = .{};
    try p.index(p.ctx, &ref, "# New", .text, &out);
    p.commit(p.ctx);
    const v2 = try f.ix.reader();
    defer v2.release();
    try testing.expectEqualStrings("New", v2.note(fid(99)).?.title);
}

test "note_index: listeners hear changes" {
    var f = try Fixture.init();
    defer f.deinit();
    const L = struct {
        changed: u32 = 0,
        removed: u32 = 0,
        fn on(ctx: *anyopaque, ev: ni.Event) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev) {
                .note_changed => s.changed += 1,
                .note_removed => s.removed += 1,
                else => {},
            }
        }
    };
    var l: L = .{};
    try f.ix.subscribe(.{ .ctx = &l, .on_event = L.on });
    const a = try f.add("a.md", "x");
    try f.ix.commit();
    try f.ix.removeFile(a);
    try f.ix.commit();
    try f.ix.commit(); // nothing new
    try testing.expectEqual(@as(u32, 1), l.changed);
    try testing.expectEqual(@as(u32, 1), l.removed);
}
