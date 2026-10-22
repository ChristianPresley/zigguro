//! Loose objects: `objects/xx/<rest>`, zlib-compressed "<type> <len>\0"
//! header plus data. Writes are atomic (unnamed temp file, then link) and
//! skipped when the object already exists.

const std = @import("std");
const oid_mod = @import("oid.zig");
const object = @import("object.zig");
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const ObjectType = object.ObjectType;
const Object = object.Object;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const zlib = @import("zlib.zig");

/// Errors reading a loose object.
pub const ReadError = error{CorruptObject} || Allocator.Error || std.Io.File.OpenError || std.Io.File.Reader.Error;

/// Errors writing a loose object.
pub const WriteError = Allocator.Error || std.Io.Dir.CreateFileAtomicError || std.Io.File.Atomic.LinkError ||
    std.Io.File.Writer.Error || error{WriteFailed};

/// Permissions for immutable object files: 0444, or the read-only
/// attribute on Windows (0.16's `Permissions.setReadOnly` does not compile
/// there).
pub fn readOnlyPermissions() std.Io.File.Permissions {
    const P = std.Io.File.Permissions;
    if (@import("builtin").os.tag == .windows) return @enumFromInt(0x1); // FILE_ATTRIBUTE_READONLY
    return P.default_file.setReadOnly(true);
}

/// Relative path "xx/<rest>" of an object inside the objects directory.
pub fn path(id: Oid, buf: *[66]u8) []const u8 {
    var hex_buf: [64]u8 = undefined;
    const h = id.hex(&hex_buf);
    buf[0] = h[0];
    buf[1] = h[1];
    buf[2] = '/';
    @memcpy(buf[3..][0 .. h.len - 2], h[2..]);
    return buf[0 .. h.len + 1];
}

/// Inflates a whole loose object from a zlib stream.
pub fn decode(gpa: Allocator, input: *std.Io.Reader) error{ CorruptObject, ReadFailed, OutOfMemory }!Object {
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var dec: flate.Decompress = .init(input, .zlib, window);
    const r = &dec.reader;
    const line = r.takeDelimiterInclusive(0) catch |e| switch (e) {
        error.StreamTooLong => return error.CorruptObject,
        else => |x| return mapRead(x, &dec),
    };
    if (line.len > 32) return error.CorruptObject;
    const hdr = try object.parseHeader(line);
    const adler = std.hash.Adler32.permute(1, line);
    if (hdr.size > std.math.maxInt(usize)) return error.OutOfMemory;
    const data = try gpa.alloc(u8, @intCast(hdr.size));
    errdefer gpa.free(data);
    r.readSliceAll(data) catch |e| return mapRead(e, &dec);
    // Reading past the end makes flate consume the trailer.
    if (r.takeByte()) |_| return error.CorruptObject else |e| switch (e) {
        error.EndOfStream => {},
        error.ReadFailed => return mapRead(e, &dec),
    }
    try zlib.checkAdler(&dec, std.hash.Adler32.permute(adler, data));
    return .{ .type = hdr.type, .data = data };
}

const mapRead = zlib.mapRead;

/// Reads a loose object; null when it does not exist. The hash is not
/// re-verified (see `Odb.verify`).
pub fn readLoose(gpa: Allocator, io: std.Io, objects_dir: std.Io.Dir, id: Oid) ReadError!?Object {
    var pbuf: [66]u8 = undefined;
    const file = objects_dir.openFile(io, path(id, &pbuf), .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => |x| return x,
    };
    defer file.close(io);
    var rbuf: [16 * 1024]u8 = undefined;
    var fr = file.reader(io, &rbuf);
    return decode(gpa, &fr.interface) catch |e| switch (e) {
        error.ReadFailed => return fr.err orelse error.CorruptObject,
        else => |x| return x,
    };
}

/// Whether a loose object exists.
pub fn exists(io: std.Io, objects_dir: std.Io.Dir, id: Oid) bool {
    var pbuf: [66]u8 = undefined;
    objects_dir.access(io, path(id, &pbuf), .{}) catch return false;
    return true;
}

/// Compresses "<type> <len>\0" ++ data as a zlib stream into `out`.
pub fn encode(gpa: Allocator, out: *std.Io.Writer, t: ObjectType, data: []const u8, level: flate.Compress.Options) (Allocator.Error || std.Io.Writer.Error)!void {
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const comp = try gpa.create(flate.Compress);
    defer gpa.destroy(comp);
    // Compress needs room for its bit writer; this grows allocating writers.
    _ = try out.writableSliceGreedy(16);
    comp.* = try .init(out, window, .zlib, level);
    var hbuf: [32]u8 = undefined;
    try comp.writer.writeAll(object.header(&hbuf, t, data.len));
    try comp.writer.writeAll(data);
    try comp.finish();
}

/// Writes a loose object atomically with mode 0444 and returns its ID.
/// Does nothing when the object already exists.
pub fn writeLoose(gpa: Allocator, io: std.Io, objects_dir: std.Io.Dir, fmt: ObjectFormat, t: ObjectType, data: []const u8) WriteError!Oid {
    const id = object.hashObject(fmt, t, data);
    if (exists(io, objects_dir, id)) return id;
    var pbuf: [66]u8 = undefined;
    var af = try objects_dir.createFileAtomic(io, path(id, &pbuf), .{
        .make_path = true,
        .permissions = readOnlyPermissions(),
    });
    defer af.deinit(io);
    var wbuf: [16 * 1024]u8 = undefined;
    var fw = af.file.writer(io, &wbuf);
    encode(gpa, &fw.interface, t, data, .default) catch |e| switch (e) {
        error.WriteFailed => return fw.err orelse error.WriteFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    fw.interface.flush() catch return fw.err orelse error.WriteFailed;
    af.link(io) catch |e| switch (e) {
        error.PathAlreadyExists => {}, // a concurrent writer won; same content
        else => |x| return x,
    };
    return id;
}

test "loose: encode/decode roundtrip in memory" {
    const t = std.testing;
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    const payload = "hello\n" ** 1000;
    try encode(t.allocator, &aw.writer, .blob, payload, .default);
    var r: std.Io.Reader = .fixed(aw.written());
    var o = try decode(t.allocator, &r);
    defer o.deinit(t.allocator);
    try t.expectEqual(ObjectType.blob, o.type);
    try t.expectEqualStrings(payload, o.data);

    // A flipped byte in the adler32 trailer is caught.
    const bad = try t.allocator.dupe(u8, aw.written());
    defer t.allocator.free(bad);
    bad[bad.len - 1] ^= 1;
    var r2: std.Io.Reader = .fixed(bad);
    try t.expectError(error.CorruptObject, decode(t.allocator, &r2));
    // Truncated stream.
    var r3: std.Io.Reader = .fixed(aw.written()[0 .. aw.written().len / 2]);
    try t.expectError(error.CorruptObject, decode(t.allocator, &r3));
}

test "loose: write then read" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const id = try writeLoose(t.allocator, io, tmp.dir, .sha1, .blob, "hello\n");
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", id.hex(&buf));
    try t.expect(exists(io, tmp.dir, id));
    // Second write is a no-op.
    _ = try writeLoose(t.allocator, io, tmp.dir, .sha1, .blob, "hello\n");
    var o = (try readLoose(t.allocator, io, tmp.dir, id)).?;
    defer o.deinit(t.allocator);
    try t.expectEqualStrings("hello\n", o.data);
    try t.expect((try readLoose(t.allocator, io, tmp.dir, Oid.zero(.sha1))) == null);
}
