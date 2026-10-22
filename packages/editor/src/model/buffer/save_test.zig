//! Saving, reloading and merging against real files in a temporary
//! directory.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const save = @import("save.zig");
const external = @import("external.zig");
const eol = @import("eol.zig");
const enc = @import("../encoding.zig");
const Document = @import("../document.zig").Document;
const ChangeSet = @import("../edit/change_set.zig").ChangeSet;
const undo_mod = @import("../edit/undo.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;
const Dir = std.Io.Dir;

/// A loaded file bound to a document.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    doc: *Document,
    file: save.FileState,
    undo: undo_mod.UndoTree,
    rt: zg_core.Runtime,

    fn init(f: *Fixture, name: []const u8, bytes: []const u8) !void {
        f.tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer f.tmp.cleanup();
        try f.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
        try f.open(name);
    }

    fn open(f: *Fixture, name: []const u8) !void {
        var l = try external.load(gpa, io, f.tmp.dir, name, null, .windows_1252);
        defer l.deinit(gpa);
        f.doc = try Document.initBytes(gpa, @enumFromInt(1), l.text);
        f.file = .{ .dir = f.tmp.dir, .path = name, .encoding = l.encoding, .eol = l.eol.style, .disk = l.disk };
        f.undo = .init(gpa, .{});
        f.rt.initTesting();
    }

    fn deinit(f: *Fixture) void {
        f.doc.deinit();
        f.undo.deinit();
        _ = f.rt.deinit();
        f.tmp.cleanup();
    }

    fn edit(f: *Fixture, start: u64, end: u64, text: []const u8) !void {
        var cs = try ChangeSet.fromEdits(gpa, f.doc.len(), &.{.{ .range = .{ .start = start, .end = end }, .text = text }});
        defer cs.deinit();
        try f.doc.applyChangeSet(&cs, .{ .user = 0 });
    }

    fn content(f: *Fixture) ![]u8 {
        return f.doc.tree.copyRange(gpa, .{ .start = 0, .end = f.doc.len() });
    }

    fn disk(f: *Fixture, name: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(io, name, gpa, .limited(1 << 24));
    }

    fn expectDisk(f: *Fixture, name: []const u8, want: []const u8) !void {
        const got = try f.disk(name);
        defer gpa.free(got);
        try std.testing.expectEqualSlices(u8, want, got);
    }

    fn entries(f: *Fixture) !usize {
        var n: usize = 0;
        var it = f.tmp.dir.iterate();
        while (try it.next(io)) |_| n += 1;
        return n;
    }
};

test "save: utf16 bom round trip" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try enc.encode(.utf16le_bom, "héllo\r\nwörld 😀\r\n", &bytes, gpa);
    var f: Fixture = undefined;
    try f.init("a.txt", bytes.items);
    defer f.deinit();
    try std.testing.expectEqual(enc.Encoding.utf16le_bom, f.file.encoding);
    // Unchanged text writes the same bytes.
    _ = try save.save(f.doc, &f.file, &f.rt, &f.undo, .{});
    try f.expectDisk("a.txt", bytes.items);
    // An edit keeps the BOM and the encoding.
    try f.edit(0, 1, "H");
    try std.testing.expect(f.doc.isDirty());
    _ = try save.save(f.doc, &f.file, &f.rt, &f.undo, .{});
    try std.testing.expect(!f.doc.isDirty());
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(gpa);
    try enc.encode(.utf16le_bom, "Héllo\r\nwörld 😀\r\n", &want, gpa);
    try f.expectDisk("a.txt", want.items);
    try std.testing.expectEqual(@as(usize, 1), try f.entries());
}

test "save: mixed eol untouched" {
    var f: Fixture = undefined;
    try f.init("m.txt", "a\r\nb\nc\rd");
    defer f.deinit();
    try std.testing.expectEqual(eol.Eol.mixed, f.file.eol);
    try f.edit(0, 0, "X");
    const r = try save.save(f.doc, &f.file, &f.rt, &f.undo, .{});
    try std.testing.expect(!r.normalized);
    try f.expectDisk("m.txt", "Xa\r\nb\nc\rd");
    // `mixed` as an override keeps the terminators too.
    _ = try save.save(f.doc, &f.file, &f.rt, &f.undo, .{ .eol_override = .mixed });
    try f.expectDisk("m.txt", "Xa\r\nb\nc\rd");
}

test "save: normalizations are one undo group" {
    const original = "a  \r\nb\t\nc  ";
    var f: Fixture = undefined;
    try f.init("n.txt", original);
    defer f.deinit();
    const r = try save.save(f.doc, &f.file, &f.rt, &f.undo, .{ .trim_trailing_whitespace = true, .insert_final_newline = true, .eol_override = .lf });
    try std.testing.expect(r.normalized);
    try f.expectDisk("n.txt", "a\nb\nc\n");
    try std.testing.expect(!f.doc.isDirty());
    try std.testing.expect(f.undo.isAtSaved());
    const nodes = f.undo.nodes();
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqualStrings("Save normalizations", nodes[1].label);
    const step = f.undo.undo().?;
    try f.doc.applyChangeSet(step.changes, .undo);
    const t = try f.content();
    defer gpa.free(t);
    try std.testing.expectEqualStrings(original, t);
    try std.testing.expect(!f.undo.isAtSaved());
    // A clean text needs no normalization.
    var clean = try Document.initBytes(gpa, @enumFromInt(3), "a\r\nb\r\n");
    defer clean.deinit();
    try std.testing.expectEqual(@as(?ChangeSet, null), try save.normalizationChanges(gpa, clean.tree, .{ .eol_override = .crlf, .trim_trailing_whitespace = true, .insert_final_newline = true }));
}

test "save: final newline uses the dominant terminator" {
    var f: Fixture = undefined;
    try f.init("d.txt", "a\r\nb\r\nc");
    defer f.deinit();
    _ = try save.save(f.doc, &f.file, &f.rt, &f.undo, .{ .insert_final_newline = true });
    try f.expectDisk("d.txt", "a\r\nb\r\nc\r\n");
    // An empty file stays empty.
    try f.edit(0, f.doc.len(), "");
    _ = try save.save(f.doc, &f.file, &f.rt, &f.undo, .{ .insert_final_newline = true });
    try f.expectDisk("d.txt", "");
}

test "save: crash before replace leaves original" {
    const original = "original contents\n" ** 1000;
    var f: Fixture = undefined;
    try f.init("c.txt", original);
    defer f.deinit();
    try f.edit(0, f.doc.len(), "new contents\n" ** 2000);
    var b = try save.begin(f.doc, &f.file, &f.undo, .{}, .zero);
    defer b.job.deinit();
    // Fail half way through the writes.
    b.job.fail_after = f.doc.len() / 2;
    try std.testing.expectError(error.NoSpaceLeft, b.job.run(io));
    try f.expectDisk("c.txt", original);
    try std.testing.expectEqual(@as(usize, 1), try f.entries());
    try std.testing.expect(f.doc.isDirty());
}

test "save: unrepresentable text leaves original" {
    var f: Fixture = undefined;
    try f.init("w.txt", "caf\xE9\n");
    defer f.deinit();
    try std.testing.expectEqual(enc.Encoding.windows_1252, f.file.encoding);
    try f.edit(0, 0, "日本 ");
    var b = try save.begin(f.doc, &f.file, null, .{}, .zero);
    defer b.job.deinit();
    try std.testing.expectError(error.Unrepresentable, b.job.run(io));
    try std.testing.expectEqual(@as(?u64, 0), b.job.unrepresentable_at);
    try f.expectDisk("w.txt", "caf\xE9\n");
    // Saving as UTF-8 instead works.
    _ = try save.save(f.doc, &f.file, &f.rt, null, .{ .encoding_override = .utf8 });
    try f.expectDisk("w.txt", "日本 café\n");
    try std.testing.expectEqual(enc.Encoding.utf8, f.file.encoding);
}

test "save: large single-byte text is encoded in pieces" {
    var f: Fixture = undefined;
    try f.init("big.txt", "\xE9");
    defer f.deinit();
    // 3 MiB of two-byte characters: pieces cut on character boundaries.
    const big = try gpa.alloc(u8, 3 << 20);
    defer gpa.free(big);
    for (0..big.len / 2) |k| @memcpy(big[2 * k ..][0..2], "é");
    try f.edit(0, f.doc.len(), big);
    try f.edit(0, 0, "a");
    _ = try save.save(f.doc, &f.file, &f.rt, null, .{});
    const got = try f.disk("big.txt");
    defer gpa.free(got);
    try std.testing.expectEqual(@as(usize, big.len / 2 + 1), got.len);
    for (got[1..]) |c| try std.testing.expectEqual(@as(u8, 0xE9), c);
}

test "save: symlink target written in place" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    f.tmp = std.testing.tmpDir(.{ .iterate = true });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "old\n" });
    try f.tmp.dir.symLink(io, "target.txt", "link.txt", .{});
    try f.tmp.dir.createDirPath(io, "backup");
    try f.open("link.txt");
    defer f.deinit();
    var backup = try f.tmp.dir.openDir(io, "backup", .{});
    defer backup.close(io);
    try f.edit(0, 3, "new");
    const r = try save.save(f.doc, &f.file, &f.rt, null, .{ .backup_dir = backup });
    try std.testing.expect(r.in_place);
    const st = try f.tmp.dir.statFile(io, "link.txt", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, st.kind);
    try f.expectDisk("target.txt", "new\n");
    const name = std.fmt.hex(save.hashBytes("link.txt"));
    const kept = try backup.readFileAlloc(io, &name, gpa, .limited(1 << 10));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("old\n", kept);
    // Shrinking cuts the file to the new length.
    try f.edit(0, f.doc.len(), "x");
    _ = try save.save(f.doc, &f.file, &f.rt, null, .{});
    try f.expectDisk("target.txt", "x");
}

test "save: hard link keeps both names" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    f.tmp = std.testing.tmpDir(.{ .iterate = true });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "shared\n" });
    try f.tmp.dir.hardLink("one.txt", f.tmp.dir, "two.txt", io, .{});
    try f.open("one.txt");
    defer f.deinit();
    try f.edit(0, 0, "still ");
    const r = try save.save(f.doc, &f.file, &f.rt, null, .{});
    try std.testing.expect(r.in_place);
    try f.expectDisk("two.txt", "still shared\n");
}

test "save: external change conflict detected" {
    var f: Fixture = undefined;
    try f.init("e.txt", "v1\n");
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "e.txt", .data = "changed elsewhere\n" });
    try f.edit(0, 0, "mine ");
    try std.testing.expectError(error.ExternalChangeConflict, save.save(f.doc, &f.file, &f.rt, null, .{}));
    try f.expectDisk("e.txt", "changed elsewhere\n");
    // The user chose "overwrite".
    _ = try save.save(f.doc, &f.file, &f.rt, null, .{ .overwrite = true });
    try f.expectDisk("e.txt", "mine v1\n");
    // Rewriting the same bytes (a touch) is not a conflict.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "e.txt", .data = "mine v1\n" });
    try f.edit(0, 0, ">");
    _ = try save.save(f.doc, &f.file, &f.rt, null, .{});
    try f.expectDisk("e.txt", ">mine v1\n");
}

test "save: read-only file fails with AccessDenied" {
    var f: Fixture = undefined;
    try f.init("ro.txt", "locked\n");
    defer f.deinit();
    {
        var file = try f.tmp.dir.openFile(io, "ro.txt", .{ .mode = .read_write });
        defer file.close(io);
        const st = try file.stat(io);
        try file.setPermissions(io, save.withReadOnly(st.permissions, true));
    }
    f.file.disk = null;
    try f.edit(0, 0, "x");
    try std.testing.expectError(error.AccessDenied, save.save(f.doc, &f.file, &f.rt, null, .{}));
    try f.expectDisk("ro.txt", "locked\n");
    var file = try f.tmp.dir.openFile(io, "ro.txt", .{});
    defer file.close(io);
    const st = try file.stat(io);
    try file.setPermissions(io, save.withReadOnly(st.permissions, false));
}

test "save: permissions preserved" {
    if (comptime !std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest else {
        var f: Fixture = undefined;
        try f.init("run.sh", "#!/bin/sh\n");
        defer f.deinit();
        {
            var file = try f.tmp.dir.openFile(io, "run.sh", .{});
            defer file.close(io);
            try file.setPermissions(io, .fromMode(0o750));
        }
        f.file.disk = null;
        try f.edit(f.doc.len(), f.doc.len(), "true\n");
        _ = try save.save(f.doc, &f.file, &f.rt, null, .{});
        const st = try f.tmp.dir.statFile(io, "run.sh", .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o750), st.permissions.toMode() & 0o777);
    }
}

test "save: new file is created" {
    var f: Fixture = undefined;
    try f.init("x.txt", "");
    defer f.deinit();
    f.file.path = "sub-new.txt";
    f.file.disk = null;
    try f.edit(0, 0, "fresh\n");
    _ = try save.save(f.doc, &f.file, &f.rt, null, .{});
    try f.expectDisk("sub-new.txt", "fresh\n");
}

test "reload: clean buffer keeps cursor line" {
    var f: Fixture = undefined;
    try f.init("r.txt", "one\ntwo\nthree\nfour\nfive\n");
    defer f.deinit();
    const v0 = f.doc.version;
    const cursor = f.doc.tree.lineStart(3) + 2; // "fo|ur"
    try f.tmp.dir.writeFile(io, .{ .sub_path = "r.txt", .data = "ONE!\ntwo\nthree\nfour\nfive\nsix\n" });
    const ch = try external.onWatchEvent(f.doc, &f.file, &f.rt, &f.undo);
    try std.testing.expectEqual(external.ExternalChange.reloaded_clean, ch);
    const t = try f.content();
    defer gpa.free(t);
    try std.testing.expectEqualStrings("ONE!\ntwo\nthree\nfour\nfive\nsix\n", t);
    const moved = f.doc.mapForward(v0, .{ .start = cursor, .end = cursor }, .right).?;
    try std.testing.expectEqual(@as(u64, 3), f.doc.tree.lineOf(moved.start));
    try std.testing.expectEqual(f.doc.tree.lineStart(3) + 2, moved.start);
    try std.testing.expect(!f.doc.isDirty());
    try std.testing.expectEqualStrings("Reload from disk", f.undo.nodes()[f.undo.nodes().len - 1].label);
    // Nothing changed since: no event.
    try std.testing.expectEqual(external.ExternalChange.none, try external.onWatchEvent(f.doc, &f.file, &f.rt, &f.undo));
}

test "reload: dirty buffer reports conflict, deletion reported" {
    var f: Fixture = undefined;
    try f.init("k.txt", "base\n");
    defer f.deinit();
    try f.edit(0, 0, "mine ");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "k.txt", .data = "theirs base\n" });
    var ch = try external.onWatchEvent(f.doc, &f.file, &f.rt, &f.undo);
    try std.testing.expect(ch == .conflict);
    defer ch.conflict.deinit(gpa);
    try std.testing.expectEqualStrings("theirs base\n", ch.conflict.theirs);
    var m = try external.merge3(gpa, "base\n", "mine base\n", ch.conflict.theirs, .{});
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), m.conflicts);
    try f.tmp.dir.deleteFile(io, "k.txt");
    try std.testing.expectEqual(external.ExternalChange.deleted, try external.onWatchEvent(f.doc, &f.file, &f.rt, &f.undo));
    try std.testing.expectEqual(external.ExternalChange.none, try external.onWatchEvent(f.doc, &f.file, &f.rt, &f.undo));
}

test "reload: terminator-only change is applied" {
    var f: Fixture = undefined;
    try f.init("t.txt", "a\nb\nc\n");
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "t.txt", .data = "a\r\nb\r\nc\r\n" });
    try std.testing.expectEqual(external.ExternalChange.reloaded_clean, try external.onWatchEvent(f.doc, &f.file, &f.rt, null));
    const t = try f.content();
    defer gpa.free(t);
    try std.testing.expectEqualStrings("a\r\nb\r\nc\r\n", t);
    try std.testing.expectEqual(eol.Eol.crlf, f.file.eol);
}

test "reload: changes cover only differing bytes" {
    var d = try Document.initBytes(gpa, @enumFromInt(2), "keep\nold line here\nkeep\n");
    defer d.deinit();
    var cs = (try external.reloadChanges(gpa, d.tree, "keep\nnew line here\nkeep\n")).?;
    defer cs.deinit();
    try std.testing.expectEqual(@as(usize, 1), cs.replaces.len);
    try std.testing.expectEqual(@as(u64, 5), cs.replaces[0].range.start);
    try std.testing.expectEqual(@as(u64, 8), cs.replaces[0].range.end);
    try std.testing.expectEqualStrings("new", cs.replaces[0].text);
    try std.testing.expectEqual(@as(?ChangeSet, null), try external.reloadChanges(gpa, d.tree, "keep\nold line here\nkeep\n"));
}

test "merge3: non-overlapping changes merge cleanly; overlapping produce markers" {
    const base = "a\nb\nc\nd\ne\nf\n";
    {
        var m = try external.merge3(gpa, base, "A\nb\nc\nd\ne\nf\n", "a\nb\nc\nd\ne\nF\nG\n", .{});
        defer m.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 0), m.conflicts);
        try std.testing.expectEqualStrings("A\nb\nc\nd\ne\nF\nG\n", m.text);
    }
    {
        // The same change on both sides is not a conflict.
        var m = try external.merge3(gpa, base, "a\nb\nX\nd\ne\nf\n", "a\nb\nX\nd\ne\nF\n", .{});
        defer m.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 0), m.conflicts);
        try std.testing.expectEqualStrings("a\nb\nX\nd\ne\nF\n", m.text);
    }
    {
        var m = try external.merge3(gpa, base, "a\nb\nmine\nd\ne\nf\n", "a\nb\ntheirs\nd\ne\nf", .{ .mine = "buffer", .theirs = "disk" });
        defer m.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 1), m.conflicts);
        try std.testing.expectEqualStrings("a\nb\n<<<<<<< buffer\nmine\n=======\ntheirs\n>>>>>>> disk\nd\ne\nf", m.text);
    }
    {
        // Deleting a line one side while the other edits elsewhere.
        var m = try external.merge3(gpa, base, "a\nc\nd\ne\nf\n", "a\nb\nc\nd\nE\nf\n", .{});
        defer m.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 0), m.conflicts);
        try std.testing.expectEqualStrings("a\nc\nd\nE\nf\n", m.text);
    }
}
