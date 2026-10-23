const std = @import("std");
const zg_ai = @import("zg_ai");
const store_mod = @import("store.zig");
const save = @import("save.zig");
const runs = @import("../runs/root.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;
const ArtifactStore = store_mod.ArtifactStore;
const ArtifactId = store_mod.ArtifactId;

const Outputs = struct {
    got: std.ArrayList(u8) = .empty,
    run: ?runs.RunId = null,

    fn add(ctx: *anyopaque, run: runs.RunId, artifact: []const u8) void {
        const o: *Outputs = @ptrCast(@alignCast(ctx));
        o.run = run;
        o.got.appendSlice(gpa, artifact) catch unreachable;
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    clock: zg_ai.ratelimit.FakeClock,
    outputs: Outputs = .{},
    s: *ArtifactStore,

    fn init(f: *Fx) !void {
        f.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .clock = .init(1_760_000_000_000), .s = undefined };
        f.s = try f.open();
    }

    fn open(f: *Fx) !*ArtifactStore {
        return ArtifactStore.open(gpa, io, f.tmp.dir, .{ .clock = f.clock.clock(), .outputs = .{ .ctx = &f.outputs, .add = Outputs.add } });
    }

    fn deinit(f: *Fx) void {
        f.s.close();
        f.outputs.got.deinit(gpa);
        f.tmp.cleanup();
    }
};

test "artifact ids" {
    const id: ArtifactId = .{ .n = 0x0123_4567_89AB_CDEF };
    const t = id.text();
    try testing.expectEqualStrings("A-", t[0..2]);
    try testing.expectEqual(id.n, ArtifactId.parse(&t).?.n);
    var lower = t;
    for (lower[2..]) |*c| c.* = std.ascii.toLower(c.*);
    try testing.expectEqual(id.n, ArtifactId.parse(&lower).?.n);
    const max: ArtifactId = .{ .n = std.math.maxInt(u64) };
    try testing.expectEqualStrings("A-FZZZZZZZZZZZZ", &max.text());
    try testing.expect(ArtifactId.parse("A-GZZZZZZZZZZZZ") == null);
    try testing.expect(ArtifactId.parse("A-123") == null);
    try testing.expect(ArtifactId.parse("B-0000000000000") == null);
    try testing.expect(ArtifactId.parse("A-000000000000U") == null);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(&t, try std.fmt.bufPrint(&buf, "{f}", .{id}));
}

test "create_update_versions_immutable" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const id = try f.s.create(.{ .kind = .markdown, .title = "Findings", .content = "# One\n" });
    f.clock.advance(1000);
    try testing.expectEqual(@as(u32, 2), try f.s.update(id, "# Two\n", "second draft"));
    try testing.expectEqual(@as(u32, 3), try f.s.update(id, "# Three\n", null));

    const v1 = try f.s.read(id, 1, a);
    try testing.expectEqualStrings("# One\n", v1.bytes);
    try testing.expectEqual(@as(u32, 3), v1.versions);
    const latest = try f.s.read(id, null, a);
    try testing.expectEqualStrings("# Three\n", latest.bytes);
    try testing.expectEqual(@as(u32, 3), latest.version);
    try testing.expectError(error.UnknownVersion, f.s.read(id, 4, a));
    try testing.expectError(error.UnknownArtifact, f.s.read(.{ .n = 7 }, null, a));

    // Each version is its own file, untouched by later ones.
    const name = id.text();
    var sub = try f.tmp.dir.openDir(io, &name, .{});
    defer sub.close(io);
    try testing.expectEqualStrings("# One\n", try sub.readFileAlloc(io, "v1.md", a, .limited(100)));
    try testing.expectEqualStrings("# Two\n", try sub.readFileAlloc(io, "v2.md", a, .limited(100)));

    const meta = (try f.s.get(id, a)).?;
    try testing.expectEqualStrings("second draft", meta.versions[1].note.?);
    try testing.expectEqual(@as(i64, 1_760_000_001_000), meta.versions[1].created);
    try testing.expectEqual(@as(u64, 6), meta.versions[0].size);

    // Invalid content is refused with a message and adds no version.
    var why: []const u8 = "";
    try testing.expectError(error.Invalid, f.s.updateChecked(a, id, "\xff", .{}, &why));
    try testing.expectEqualStrings("markdown artifacts must be UTF-8 text", why);
    try testing.expectEqual(@as(usize, 3), (try f.s.get(id, a)).?.versions.len);

    // Artifacts survive a restart.
    f.s.close();
    f.s = try f.open();
    try testing.expectEqual(@as(u32, 0), f.s.load_errors);
    const again = (try f.s.get(id, a)).?;
    try testing.expectEqualStrings("Findings", again.title);
    try testing.expectEqual(@as(usize, 3), again.versions.len);
    try testing.expectEqualStrings("# Two\n", (try f.s.read(id, 2, a)).bytes);
}

test "dedupe_identical_versions" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.s.create(.{ .kind = .table, .title = "t", .content = "a,b\n1,2\n" });
    try testing.expectEqual(@as(u32, 1), try f.s.update(id, "a,b\n1,2\n", "same"));
    try testing.expectEqual(@as(u32, 2), try f.s.update(id, "a,b\n1,3\n", null));
    try testing.expectEqual(@as(u32, 2), try f.s.update(id, "a,b\n1,3\n", null));
    // Going back to an older content is a new version.
    try testing.expectEqual(@as(u32, 3), try f.s.update(id, "a,b\n1,2\n", null));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const meta = (try f.s.get(id, arena.allocator())).?;
    try testing.expectEqual(@as(usize, 3), meta.versions.len);
    try testing.expectEqualStrings(meta.versions[0].blake3, meta.versions[2].blake3);
}

test "provenance_recorded" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(1);
    const run = runs.RunId.generateAt(1_760_000_000_000, prng.random());
    const other = runs.RunId.generateAt(1_760_000_000_001, prng.random());

    const id = try f.s.create(.{ .kind = .markdown, .title = "R", .content = "x", .run = run, .session = "S-1", .tool_call = "toolu_1" });
    _ = try f.s.updateChecked(a, id, "y", .{ .prov = .{ .run = other, .tool_call = "toolu_2" } }, undefined);
    _ = try f.s.create(.{ .kind = .text, .title = "no run", .content = "z" });

    // The run's outputs list the artifact.
    try testing.expectEqualStrings(&id.text(), f.outputs.got.items);
    try testing.expect(f.outputs.run.?.eql(run));

    const meta = (try f.s.get(id, a)).?;
    try testing.expectEqualStrings(&run.text(), meta.run.?);
    try testing.expectEqualStrings(&run.text(), meta.versions[0].run.?);
    try testing.expectEqualStrings("S-1", meta.versions[0].session.?);
    try testing.expectEqualStrings("toolu_1", meta.versions[0].tool_call.?);
    try testing.expectEqualStrings(&other.text(), meta.versions[1].run.?);
    try testing.expectEqualStrings("toolu_2", meta.versions[1].tool_call.?);
    try testing.expect(meta.versions[1].session == null);

    var list: std.ArrayList(store_mod.Artifact) = .empty;
    try f.s.list(.{ .run = run }, &list, a);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    list.clearRetainingCapacity();
    try f.s.list(.{}, &list, a);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("R", list.items[0].title);
    list.clearRetainingCapacity();
    try f.s.list(.{ .kind = .text }, &list, a);
    try testing.expectEqualStrings("no run", list.items[0].title);
}

test "import files" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "out.csv", .data = "x,y\n1,2\n" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "notes.json", .data = "{\"not\": \"a table\"" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = "0123456789" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "fit.py", .data = "print(1)\n" });
    const base = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&f.tmp.sub_path});

    const csv = try f.s.importFile(try std.fs.path.join(a, &.{ base, "out.csv" }), null);
    const m1 = (try f.s.get(csv, a)).?;
    try testing.expectEqual(store_mod.ArtifactKind.table, m1.kind);
    try testing.expectEqualStrings("out.csv", m1.title);
    try testing.expectEqualStrings("csv", m1.latest().ext);

    // JSON that isn't a table is kept as text.
    const js = try f.s.importFile(try std.fs.path.join(a, &.{ base, "notes.json" }), null);
    try testing.expectEqual(store_mod.ArtifactKind.text, (try f.s.get(js, a)).?.kind);

    const py = try f.s.importFile(try std.fs.path.join(a, &.{ base, "fit.py" }), null);
    const m3 = (try f.s.get(py, a)).?;
    try testing.expectEqual(store_mod.ArtifactKind.code, m3.kind);
    try testing.expectEqualStrings("py", m3.latest().ext);

    // Over the threshold: linked, not copied.
    f.s.o.link_threshold = 5;
    const big_path = try std.fs.path.join(a, &.{ base, "big.bin" });
    const big = try f.s.importFile(big_path, null);
    const m4 = (try f.s.get(big, a)).?;
    try testing.expectEqualStrings(big_path, m4.latest().link.?);
    const c = try f.s.read(big, null, a);
    try testing.expectEqualStrings("0123456789", c.bytes);
    const name = big.text();
    var sub = try f.tmp.dir.openDir(io, &name, .{});
    defer sub.close(io);
    try testing.expectError(error.FileNotFound, sub.statFile(io, "v1.bin", .{}));
}

const Saves = struct {
    reqs: std.ArrayList(save.SaveRequest) = .empty,
    arena: std.heap.ArenaAllocator,

    fn record(ctx: *anyopaque, req: save.SaveRequest) anyerror!u64 {
        const s: *Saves = @ptrCast(@alignCast(ctx));
        const a = s.arena.allocator();
        var r = req;
        r.path = try a.dupe(u8, req.path);
        r.content = try a.dupe(u8, req.content);
        r.summary = try a.dupe(u8, req.summary);
        try s.reqs.append(a, r);
        return 40 + s.reqs.items.len;
    }
};

test "save_creates_changeset" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var saves: Saves = .{ .arena = .init(gpa) };
    defer saves.arena.deinit();
    const port: save.SavePort = .{ .ctx = &saves, .save = Saves.record };
    const id = try f.s.create(.{ .kind = .table, .title = "Q3 Revenue / by region!", .content = "a,b\n1,2\n" });
    _ = try f.s.update(id, "a,b\n3,4\n", null);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const meta = (try f.s.get(id, a)).?;
    const path = try save.proposePath(a, .{}, &meta, meta.latest());
    try testing.expectEqualStrings("data/q3-revenue-by-region.csv", path);

    try testing.expectEqual(@as(u64, 41), try f.s.saveToWorkspace(id, 1, path, port, .{}));
    const r = saves.reqs.items[0];
    try testing.expectEqualStrings("a,b\n1,2\n", r.content);
    try testing.expect(r.auto_apply);
    const want = try std.fmt.allocPrint(a, "Save artifact {s} v1 (Q3 Revenue / by region!) to data/q3-revenue-by-region.csv", .{&id.text()});
    try testing.expectEqualStrings(want, r.summary);

    _ = try f.s.saveToWorkspace(id, null, "x.csv", port, .{ .auto_apply = false });
    try testing.expectEqualStrings("a,b\n3,4\n", saves.reqs.items[1].content);
    try testing.expect(!saves.reqs.items[1].auto_apply);

    try testing.expectError(error.InvalidPath, f.s.saveToWorkspace(id, null, "../x.csv", port, .{}));
    try testing.expectError(error.InvalidPath, f.s.saveToWorkspace(id, null, "/etc/x", port, .{}));
    try testing.expectError(error.UnknownArtifact, f.s.saveToWorkspace(.{ .n = 3 }, null, "x", port, .{}));
    try testing.expectEqualStrings("artifact", try save.slug(a, "!!"));
}
