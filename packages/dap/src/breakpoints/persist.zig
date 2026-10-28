//! Breakpoints on disk (E07.F06.S03.T01):
//! `<workspace-state>/debug/breakpoints.zon`, written atomically (a
//! temporary file, then rename).
//!
//! ```zon
//! .{
//!     .version = 1,
//!     .breakpoints = .{
//!         .{ .kind = .source, .path = "src/main.zig", .line = 12, .condition = "i > 3" },
//!         .{ .kind = .function, .name = "main", .enabled = false },
//!     },
//!     .exception_filters = .{
//!         .{ .adapter_type = "lldb-dap", .filter = "cpp_throw", .enabled = true },
//!     },
//! }
//! ```
//!
//! Paths inside the workspace are stored relative to it (`/` separated);
//! others stay absolute.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const version = 1;
/// Under the workspace state directory.
pub const sub_path = "debug/breakpoints.zon";

pub const Kind = enum { source, function, data, instruction };
pub const Access = enum { read, write, readWrite };

pub const Saved = struct {
    kind: Kind,
    enabled: bool = true,
    path: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
    name: ?[]const u8 = null,
    data_id: ?[]const u8 = null,
    description: ?[]const u8 = null,
    access: ?Access = null,
    reference: ?[]const u8 = null,
    offset: ?i64 = null,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
    mode: ?[]const u8 = null,
};

pub const SavedFilter = struct {
    adapter_type: []const u8,
    filter: []const u8,
    enabled: bool,
    condition: ?[]const u8 = null,
};

pub const File = struct {
    version: u32 = version,
    breakpoints: []const Saved = &.{},
    exception_filters: []const SavedFilter = &.{},
};

pub fn encode(a: Allocator, f: File) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(a);
    std.zon.stringify.serialize(f, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.written();
}

pub const DecodeError = error{ OutOfMemory, Invalid, UnsupportedVersion };

/// Strings in `a`. The file's own shape is read by a small reader
/// (`std.zon.parse` alone takes most of the 20 ms budget for 10k
/// breakpoints); anything it does not know goes to `std.zon.parse`.
pub fn decode(a: Allocator, bytes: []const u8) DecodeError!File {
    return decodeWith(a, bytes, true);
}

/// `decode`, with or without the fast reader (tests compare the two).
pub fn decodeWith(a: Allocator, bytes: []const u8, fast_reader: bool) DecodeError!File {
    const src = try a.dupeZ(u8, bytes);
    const f = fast: {
        var r: Reader = .{ .a = a, .src = if (fast_reader) src else "" };
        break :fast r.file() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => std.zon.parse.fromSliceAlloc(File, a, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |e2| switch (e2) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseZon => return error.Invalid,
            },
        };
    };
    if (f.version != version) return error.UnsupportedVersion;
    return f;
}

/// Reads `File`: `.{ .name = value, ... }` with strings, integers,
/// `true`/`false`/`null`, enum literals and nested lists of structs.
const Reader = struct {
    a: Allocator,
    src: []const u8,
    i: usize = 0,

    const Error = error{ OutOfMemory, Syntax };

    fn skip(r: *Reader) void {
        while (r.i < r.src.len) {
            const c = r.src[r.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                r.i += 1;
            } else if (c == '/' and r.i + 1 < r.src.len and r.src[r.i + 1] == '/') {
                while (r.i < r.src.len and r.src[r.i] != '\n') r.i += 1;
            } else return;
        }
    }

    fn eat(r: *Reader, s: []const u8) bool {
        r.skip();
        if (!std.mem.startsWith(u8, r.src[r.i..], s)) return false;
        r.i += s.len;
        return true;
    }

    fn expect(r: *Reader, s: []const u8) Error!void {
        if (!r.eat(s)) return error.Syntax;
    }

    fn ident(r: *Reader) Error![]const u8 {
        r.skip();
        const start = r.i;
        while (r.i < r.src.len and (std.ascii.isAlphanumeric(r.src[r.i]) or r.src[r.i] == '_')) r.i += 1;
        if (r.i == start) return error.Syntax;
        return r.src[start..r.i];
    }

    /// Calls `field(name)` for each `.name =` of a struct literal.
    fn object(r: *Reader, ctx: anytype, comptime field: fn (@TypeOf(ctx), *Reader, []const u8) Error!void) Error!void {
        try r.expect(".{");
        while (true) {
            if (r.eat("}")) return;
            try r.expect(".");
            const name = try r.ident();
            try r.expect("=");
            try field(ctx, r, name);
            if (!r.eat(",")) {
                try r.expect("}");
                return;
            }
        }
    }

    fn list(r: *Reader, comptime T: type) Error![]const T {
        try r.expect(".{");
        var out: std.ArrayList(T) = .empty;
        while (true) {
            if (r.eat("}")) return out.items;
            var v: T = undefined;
            try r.structValue(T, &v);
            try out.append(r.a, v);
            if (!r.eat(",")) {
                try r.expect("}");
                return out.items;
            }
        }
    }

    fn structValue(r: *Reader, comptime T: type, out: *T) Error!void {
        var v: T = undefined;
        var seen: [@typeInfo(T).@"struct".fields.len]bool = @splat(false);
        const Ctx = struct { v: *T, seen: *@TypeOf(seen) };
        try r.object(Ctx{ .v = &v, .seen = &seen }, struct {
            fn f(c: Ctx, rr: *Reader, name: []const u8) Error!void {
                inline for (@typeInfo(T).@"struct".fields, 0..) |fd, k| if (std.mem.eql(u8, fd.name, name)) {
                    @field(c.v, fd.name) = try rr.value(fd.type);
                    c.seen[k] = true;
                    return;
                };
                return error.Syntax; // unknown: let std.zon.parse decide
            }
        }.f);
        inline for (@typeInfo(T).@"struct".fields, 0..) |fd, k| if (!seen[k]) {
            const d = fd.defaultValue() orelse return error.Syntax;
            @field(v, fd.name) = d;
        };
        out.* = v;
    }

    fn value(r: *Reader, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .optional => |o| {
                if (r.eat("null")) return null;
                return try r.value(o.child);
            },
            .bool => {
                if (r.eat("true")) return true;
                if (r.eat("false")) return false;
                return error.Syntax;
            },
            .int => {
                r.skip();
                const start = r.i;
                if (r.i < r.src.len and r.src[r.i] == '-') r.i += 1;
                while (r.i < r.src.len and std.ascii.isDigit(r.src[r.i])) r.i += 1;
                return std.fmt.parseInt(T, r.src[start..r.i], 10) catch error.Syntax;
            },
            .@"enum" => {
                try r.expect(".");
                return std.meta.stringToEnum(T, try r.ident()) orelse error.Syntax;
            },
            .pointer => |p| {
                if (p.child == u8) return r.string();
                return r.list(p.child);
            },
            else => @compileError("unsupported " ++ @typeName(T)),
        }
    }

    fn string(r: *Reader) Error![]const u8 {
        r.skip();
        if (r.i >= r.src.len or r.src[r.i] != '"') return error.Syntax;
        const start = r.i;
        r.i += 1;
        var escaped = false;
        while (r.i < r.src.len and r.src[r.i] != '"') : (r.i += 1) {
            if (r.src[r.i] == '\\') {
                escaped = true;
                r.i += 1;
            } else if (r.src[r.i] == '\n') return error.Syntax;
        }
        if (r.i >= r.src.len) return error.Syntax;
        r.i += 1;
        if (!escaped) return r.src[start + 1 .. r.i - 1];
        return std.zig.string_literal.parseAlloc(r.a, r.src[start..r.i]) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Syntax,
        };
    }

    fn file(r: *Reader) Error!File {
        var f: File = undefined;
        try r.structValue(File, &f);
        r.skip();
        if (r.i != r.src.len) return error.Syntax;
        return f;
    }
};

/// `path` relative to `root` (with `/`) when inside it, else `path`.
pub fn relativize(a: Allocator, root: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (root.len == 0) return path;
    const r = std.mem.trimEnd(u8, root, "/\\");
    if (path.len <= r.len + 1 or !std.mem.startsWith(u8, path, r) or (path[r.len] != '/' and path[r.len] != '\\')) return path;
    const rel = try a.dupe(u8, path[r.len + 1 ..]);
    std.mem.replaceScalar(u8, rel, '\\', '/');
    return rel;
}

/// The inverse of `relativize` (native separators for `os`).
pub fn absolutize(a: Allocator, root: []const u8, path: []const u8, os: std.Target.Os.Tag) Allocator.Error![]const u8 {
    if (root.len == 0 or isAbsolute(path)) return path;
    const sep: u8 = if (os == .windows) '\\' else '/';
    const r = std.mem.trimEnd(u8, root, "/\\");
    const out = try std.fmt.allocPrint(a, "{s}{c}{s}", .{ r, sep, path });
    if (os == .windows) std.mem.replaceScalar(u8, out[r.len..], '/', '\\');
    return out;
}

fn isAbsolute(p: []const u8) bool {
    if (p.len > 0 and (p[0] == '/' or p[0] == '\\')) return true;
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/');
}

/// Writes `bytes` to `path` in `dir` through a temporary file, creating
/// missing parent directories.
pub fn writeAtomic(io: Io, dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    var af = try dir.createFileAtomic(io, path, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.file.sync(io);
    try af.replace(io);
}
