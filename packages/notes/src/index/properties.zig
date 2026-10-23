//! The vault-wide property type registry (E08.F06.S01.T02). Per property
//! name (case-insensitive, as Obsidian), it counts the types notes imply.
//! The authoritative type is the user's choice when set (saved in
//! `<vault>/.zigguro/types.zon`, written atomically), else the majority
//! of the known types. Notes whose value conflicts with it are listed for
//! a warning icon.

const std = @import("std");
const note = @import("../vault/note.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const PropertyType = note.PropertyType;
const FileId = note.FileId;

pub const PropertyInfo = struct {
    /// As first written.
    name: []const u8,
    ty: PropertyType,
    user_set: bool,
    /// Notes using the property.
    count: u32,
    counts: [std.meta.fields(PropertyType).len]u32,
    /// Notes whose value implies another (known) type.
    conflicts: []const FileId,
};

/// The `types.zon` shape.
pub const TypesFile = struct {
    types: []const struct { name: []const u8, type: PropertyType } = &.{},
};

/// User-assigned types, by lowercased name.
pub const Overrides = struct {
    map: std.StringHashMapUnmanaged(PropertyType) = .empty,

    pub fn deinit(o: *Overrides, gpa: Allocator) void {
        var it = o.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        o.map.deinit(gpa);
    }

    pub fn set(o: *Overrides, gpa: Allocator, name: []const u8, ty: ?PropertyType) !void {
        const key = try lowerDup(gpa, name);
        if (ty) |t| {
            const gop = try o.map.getOrPut(gpa, key);
            if (gop.found_existing) gpa.free(key);
            gop.value_ptr.* = t;
        } else {
            defer gpa.free(key);
            if (o.map.fetchRemove(key)) |kv| gpa.free(kv.key);
        }
    }

    pub fn get(o: *const Overrides, name: []const u8) ?PropertyType {
        var buf: [256]u8 = undefined;
        if (name.len > buf.len) return null;
        return o.map.get(std.ascii.lowerString(&buf, name));
    }

    /// Reads `types.zon` (missing or malformed: no overrides).
    pub fn load(o: *Overrides, gpa: Allocator, io: Io, dir: Io.Dir) !void {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const src = dir.readFileAlloc(io, ".zigguro/types.zon", a, .limited(1 << 20)) catch return;
        const z = try a.dupeZ(u8, src);
        const f = std.zon.parse.fromSliceAlloc(TypesFile, a, z, null, .{ .ignore_unknown_fields = true }) catch return;
        for (f.types) |t| try o.set(gpa, t.name, t.type);
    }

    /// Writes `types.zon` atomically.
    pub fn save(o: *const Overrides, gpa: Allocator, io: Io, dir: Io.Dir) !void {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        var it = o.map.keyIterator();
        while (it.next()) |k| try names.append(gpa, k.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        var w: Io.Writer.Allocating = .init(gpa);
        defer w.deinit();
        try w.writer.writeAll(".{\n    .types = .{\n");
        for (names.items) |n| try w.writer.print("        .{{ .name = \"{f}\", .type = .{t} }},\n", .{ std.zig.fmtString(n), o.map.get(n).? });
        try w.writer.writeAll("    },\n}\n");
        try dir.createDirPath(io, ".zigguro");
        var af = try dir.createFileAtomic(io, ".zigguro/types.zon", .{ .replace = true });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, w.written());
        try af.replace(io);
    }
};

fn lowerDup(gpa: Allocator, s: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, s);
    _ = std.ascii.lowerString(out, out);
    return out;
}

/// Accumulates per-note property types into `PropertyInfo`s.
pub const Builder = struct {
    arena: Allocator,
    by_name: std.StringHashMapUnmanaged(usize) = .empty,
    infos: std.ArrayList(Acc) = .empty,

    const Acc = struct {
        name: []const u8,
        counts: [std.meta.fields(PropertyType).len]u32 = @splat(0),
        notes: std.ArrayList(struct { id: FileId, ty: PropertyType }) = .empty,
    };

    pub fn add(b: *Builder, id: FileId, name: []const u8, ty: PropertyType) !void {
        var buf: [256]u8 = undefined;
        const lower = if (name.len <= buf.len) std.ascii.lowerString(&buf, name) else name;
        const gop = try b.by_name.getOrPut(b.arena, lower);
        if (!gop.found_existing) {
            gop.key_ptr.* = try b.arena.dupe(u8, lower);
            gop.value_ptr.* = b.infos.items.len;
            try b.infos.append(b.arena, .{ .name = name });
        }
        const acc = &b.infos.items[gop.value_ptr.*];
        acc.counts[@intFromEnum(ty)] += 1;
        try acc.notes.append(b.arena, .{ .id = id, .ty = ty });
    }

    /// The registry, sorted by name, with `overrides` applied.
    pub fn finish(b: *Builder, overrides: *const Overrides) ![]const PropertyInfo {
        const out = try b.arena.alloc(PropertyInfo, b.infos.items.len);
        for (b.infos.items, out) |*acc, *info| {
            const user = overrides.get(acc.name);
            const ty = user orelse majority(acc.counts);
            var conflicts: std.ArrayList(FileId) = .empty;
            for (acc.notes.items) |n| {
                if (n.ty == .unknown or ty == .unknown or compatible(ty, n.ty)) continue;
                try conflicts.append(b.arena, n.id);
            }
            var total: u32 = 0;
            for (acc.counts) |c| total += c;
            info.* = .{ .name = acc.name, .ty = ty, .user_set = user != null, .count = total, .counts = acc.counts, .conflicts = conflicts.items };
        }
        std.mem.sort(PropertyInfo, out, {}, struct {
            fn lt(_: void, x: PropertyInfo, y: PropertyInfo) bool {
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.lt);
        return out;
    }
};

/// The most common known type (ties: the earlier in `PropertyType`).
pub fn majority(counts: [std.meta.fields(PropertyType).len]u32) PropertyType {
    var best: PropertyType = .unknown;
    var best_n: u32 = 0;
    for (counts, 0..) |c, i| {
        const t: PropertyType = @enumFromInt(i);
        if (t == .unknown) continue;
        if (c > best_n) {
            best = t;
            best_n = c;
        }
    }
    return best;
}

/// Whether a note's inferred type fits the registry type: a single value
/// fits a list type, a date fits a datetime and the reverse.
fn compatible(registry: PropertyType, inferred: PropertyType) bool {
    if (registry == inferred) return true;
    return switch (registry) {
        .list, .tags, .aliases => inferred == .text or inferred == .list,
        .datetime => inferred == .date,
        .date => inferred == .datetime,
        .text => inferred == .number or inferred == .date or inferred == .datetime,
        else => false,
    };
}

test "properties: majority, user override and conflicts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var b: Builder = .{ .arena = a };
    const id = struct {
        fn f(i: u32) FileId {
            return .{ .index = i, .gen = 0 };
        }
    }.f;
    try b.add(id(1), "Rating", .number);
    try b.add(id(2), "rating", .number);
    try b.add(id(3), "rating", .checkbox);
    try b.add(id(4), "rating", .unknown);
    try b.add(id(1), "due", .date);
    try b.add(id(2), "due", .text);
    var o: Overrides = .{};
    defer o.deinit(std.testing.allocator);
    try o.set(std.testing.allocator, "Due", .datetime);
    const infos = try b.finish(&o);
    try std.testing.expectEqualStrings("due", infos[0].name);
    try std.testing.expectEqual(PropertyType.datetime, infos[0].ty);
    try std.testing.expect(infos[0].user_set);
    try std.testing.expectEqual(@as(usize, 1), infos[0].conflicts.len);
    try std.testing.expectEqual(PropertyType.number, infos[1].ty);
    try std.testing.expectEqual(@as(u32, 4), infos[1].count);
    try std.testing.expectEqual(@as(usize, 1), infos[1].conflicts.len);
    try std.testing.expectEqual(@as(u32, 3), infos[1].conflicts[0].index);
}

test "properties: types.zon roundtrip" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var o: Overrides = .{};
    defer o.deinit(gpa);
    try o.set(gpa, "Status", .text);
    try o.set(gpa, "when", .date);
    try o.save(gpa, io, tmp.dir);
    var back: Overrides = .{};
    defer back.deinit(gpa);
    try back.load(gpa, io, tmp.dir);
    try std.testing.expectEqual(PropertyType.date, back.get("WHEN").?);
    try std.testing.expectEqual(PropertyType.text, back.get("status").?);
    try back.set(gpa, "status", null);
    try std.testing.expect(back.get("status") == null);
}
