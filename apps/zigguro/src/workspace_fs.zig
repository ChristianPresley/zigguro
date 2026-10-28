//! The file operations workspace edits use (E07.F04.S02.T01), on disk.
//!
//! Deleted and overwritten files move to a trash folder the undo restores
//! them from. It lives in the workspace (`.zigguro/trash`), on the same
//! volume as the files, so trashing is a rename and never a copy; an
//! entry is deleted when the undo that could restore it is dropped.

const std = @import("std");
const zg_codeintel = @import("zg_codeintel");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const plan = zg_codeintel.edits.plan;

pub const DiskFs = struct {
    io: Io,
    /// Absolute.
    trash_root: []const u8,
    next: u32 = 0,

    pub fn ops(d: *DiskFs) plan.FileOps {
        return .{ .ctx = d, .vtable = &vtable };
    }

    const vtable: plan.FileOps.VTable = .{
        .kind = kind,
        .read = read,
        .write = write,
        .move = move,
        .trash = trash,
        .restore = restore,
        .forget = forget,
    };

    fn self(ctx: *anyopaque) *DiskFs {
        return @ptrCast(@alignCast(ctx));
    }

    fn kind(ctx: *anyopaque, path: []const u8) ?plan.FileKind {
        const st = Dir.cwd().statFile(self(ctx).io, path, .{}) catch return null;
        return if (st.kind == .directory) .dir else .file;
    }

    fn read(ctx: *anyopaque, gpa: Allocator, path: []const u8) anyerror![]u8 {
        return Dir.cwd().readFileAlloc(self(ctx).io, path, gpa, .limited(256 << 20));
    }

    fn makeParent(io: Io, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try Dir.cwd().createDirPath(io, parent);
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
        const io = self(ctx).io;
        try makeParent(io, path);
        try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    fn move(ctx: *anyopaque, old: []const u8, new: []const u8) anyerror!void {
        const io = self(ctx).io;
        if (kind(ctx, new) != null) return error.PathAlreadyExists;
        try makeParent(io, new);
        try Dir.rename(Dir.cwd(), old, Dir.cwd(), new, io);
    }

    fn trash(ctx: *anyopaque, gpa: Allocator, path: []const u8) anyerror![]u8 {
        const d = self(ctx);
        try Dir.cwd().createDirPath(d.io, d.trash_root);
        const ts = Io.Clock.real.now(d.io).toMilliseconds();
        const token = try std.fmt.allocPrint(gpa, "{s}{c}{d}-{d}-{s}", .{ d.trash_root, std.fs.path.sep, ts, d.next, std.fs.path.basename(path) });
        errdefer gpa.free(token);
        d.next += 1;
        try Dir.rename(Dir.cwd(), path, Dir.cwd(), token, d.io);
        return token;
    }

    fn restore(ctx: *anyopaque, token: []const u8, path: []const u8) anyerror!void {
        const io = self(ctx).io;
        try makeParent(io, path);
        try Dir.rename(Dir.cwd(), token, Dir.cwd(), path, io);
    }

    fn forget(ctx: *anyopaque, token: []const u8) void {
        Dir.cwd().deleteTree(self(ctx).io, token) catch {};
    }
};

test "workspace fs: write, move, trash and restore on disk" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPathFile(io, ".", &buf)];
    const gpa = testing.allocator;
    const at = struct {
        fn f(r: []const u8, name: []const u8) ![]u8 {
            return std.fs.path.join(testing.allocator, &.{ r, name });
        }
    }.f;
    const trash_root = try at(root, ".zigguro/trash");
    defer gpa.free(trash_root);
    var d: DiskFs = .{ .io = io, .trash_root = trash_root };
    const fs = d.ops();
    const a = try at(root, "src/a.txt");
    defer gpa.free(a);
    const b = try at(root, "lib/b.txt");
    defer gpa.free(b);

    try fs.write(a, "one\n");
    try testing.expectEqual(@as(?plan.FileKind, .file), fs.kind(a));
    try fs.move(a, b);
    try testing.expect(fs.kind(a) == null);
    try testing.expectError(error.PathAlreadyExists, fs.move(b, b));
    const tok = try fs.trash(gpa, b);
    defer gpa.free(tok);
    try testing.expect(fs.kind(b) == null);
    try fs.restore(tok, b);
    const back = try fs.read(gpa, b);
    defer gpa.free(back);
    try testing.expectEqualStrings("one\n", back);
    const tok2 = try fs.trash(gpa, b);
    defer gpa.free(tok2);
    fs.forget(tok2);
    try testing.expect(fs.kind(tok2) == null);
}
