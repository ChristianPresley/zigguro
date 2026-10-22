//! Generic ZON loader: parses any ZON text into a `Node` tree where every
//! value and every object key carries its byte span. Settings files,
//! keybinding args and extension payloads are open-ended, so they cannot go
//! through `std.zon.parse` (which needs a static result type).
//!
//! Pipeline: `std.zig.Ast.parse(.zon)` → `std.zig.ZonGen.generate` (Zoir) →
//! walk Zoir from the root, taking spans from each node's AST node. All
//! strings are copied into the `Doc` arena and the Ast/Zoir are freed.

const std = @import("std");
const diag = @import("diag.zig");
const value = @import("value.zig");

const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const Allocator = std.mem.Allocator;

/// Byte span in the source.
pub const Span = diag.Span;
/// A diagnostic.
pub const Diag = diag.Diag;
/// Diagnostic list.
pub const Diags = diag.Diags;
/// The span-free value.
pub const Value = value.Value;

/// Maximum nesting of arrays and objects.
pub const max_depth = 64;
/// Maximum source size.
pub const max_file_bytes = 8 << 20;
/// Maximum length of one string.
pub const max_string_bytes = 1 << 20;

/// One object member, with the span of its key as written.
pub const Field = struct {
    key: []const u8,
    key_span: Span,
    value: Node,
};

/// A value and the span of its source text.
pub const Node = struct {
    v: Kind,
    span: Span,

    /// The member `key` of an object node (first match), or null.
    pub fn get(n: Node, key: []const u8) ?Node {
        const fs = switch (n.v) {
            .object => |o| o,
            else => return null,
        };
        for (fs) |f| if (std.mem.eql(u8, f.key, key)) return f.value;
        return null;
    }
};

/// The node payload. Object fields stay in source order.
pub const Kind = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    enum_lit: []const u8,
    array: []const Node,
    object: []const Field,
};

/// A parsed document. Owns its source copy and every node.
pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    source: [:0]const u8,
    root: Node,
    line_starts: []const u32,

    /// 1-based line and column of byte `off`.
    pub fn lineCol(d: *const Doc, off: u32) struct { line: u32, col: u32 } {
        var lo: usize = 0;
        var hi: usize = d.line_starts.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (d.line_starts[mid] <= off) lo = mid else hi = mid;
        }
        return .{ .line = @intCast(lo + 1), .col = off - d.line_starts[lo] + 1 };
    }

    /// Frees everything.
    pub fn deinit(d: *Doc) void {
        d.arena.deinit();
        d.* = undefined;
    }
};

/// Errors of the loaders.
pub const Error = error{ OutOfMemory, Invalid };

/// Parses ZON `source`. Syntax and semantic errors go to `diags`; on any
/// error-severity diagnostic except duplicate keys the result is
/// `error.Invalid`. A duplicate key keeps the first occurrence.
pub fn loadZon(gpa: Allocator, source: [:0]const u8, diags: *Diags) Error!Doc {
    if (source.len > max_file_bytes) {
        diags.add(.none, .err, "file is larger than {d} bytes", .{max_file_bytes});
        return error.Invalid;
    }
    // Zoir has no nodes when any compile error exists, so a duplicate key is
    // blanked out of a work copy (offsets preserved) and the copy reparsed.
    var work: ?[:0]u8 = null;
    defer if (work) |wk| gpa.free(wk);
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        const src: [:0]const u8 = work orelse source;
        var ast = try Ast.parse(gpa, src, .zon);
        defer ast.deinit(gpa);
        if (ast.errors.len > 0) {
            for (ast.errors) |e| {
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                ast.renderError(e, &aw.writer) catch return error.OutOfMemory;
                const off = ast.tokenStart(e.token) + ast.errorOffset(e);
                diags.add(.{ .start = off, .end = off }, .err, "{s}", .{aw.written()});
            }
            return error.Invalid;
        }
        var zoir = try std.zig.ZonGen.generate(gpa, ast, .{ .parse_str_lits = true });
        defer zoir.deinit(gpa);
        if (zoir.compile_errors.len == 0) return walk(gpa, source, &ast, zoir, diags);
        var fatal = false;
        for (zoir.compile_errors) |e| {
            const msg = e.msg.get(zoir);
            const notes = e.getNotes(zoir);
            if (std.mem.eql(u8, msg, "duplicate struct field name") and notes.len > 0 and notes[0].token != .none and attempts < max_depth) {
                const dup = notes[0].token.unwrap().?;
                const start = ast.tokenStart(dup);
                diags.add(.{ .start = start, .end = @intCast(start + ast.tokenSlice(dup).len) }, .err, "duplicate key '{s}'; the first occurrence wins", .{ast.tokenSlice(dup)});
                if (work == null) work = try gpa.dupeZ(u8, source);
                blankField(&ast, dup, work.?);
                continue;
            }
            const span: Span = if (e.token.unwrap()) |t| blk: {
                const off = ast.tokenStart(t) + e.node_or_offset;
                break :blk .{ .start = off, .end = off };
            } else nodeSpan(&ast, @enumFromInt(e.node_or_offset));
            diags.add(span, .err, "{s}", .{msg});
            fatal = true;
        }
        if (fatal) return error.Invalid;
    }
}

/// Overwrites the field whose name token is `name_tok` (from its leading `.`
/// through its trailing comma, if any) with spaces in `buf`.
fn blankField(ast: *const Ast, name_tok: Ast.TokenIndex, buf: []u8) void {
    const start = ast.tokenStart(name_tok - 1);
    var t = name_tok + 2;
    var depth: u32 = 0;
    var end: u32 = undefined;
    while (true) : (t += 1) {
        switch (ast.tokenTag(t)) {
            .l_brace, .l_paren, .l_bracket => depth += 1,
            .r_brace, .r_paren, .r_bracket => {
                if (depth == 0) {
                    end = ast.tokenStart(t);
                    break;
                }
                depth -= 1;
            },
            .comma => if (depth == 0) {
                end = ast.tokenStart(t) + 1;
                break;
            },
            .eof => {
                end = ast.tokenStart(t);
                break;
            },
            else => {},
        }
    }
    for (buf[start..end]) |*c| {
        if (c.* != '\n') c.* = ' ';
    }
}

fn walk(gpa: Allocator, source: [:0]const u8, ast: *const Ast, zoir: Zoir, diags: *Diags) Error!Doc {
    var doc: Doc = .{ .arena = .init(gpa), .source = undefined, .root = undefined, .line_starts = undefined };
    errdefer doc.arena.deinit();
    const a = doc.arena.allocator();
    doc.source = try a.dupeZ(u8, source);
    doc.line_starts = try lineStarts(a, source);
    var w: Walker = .{ .a = a, .ast = ast, .zoir = zoir, .diags = diags };
    doc.root = try w.node(.root, 0);
    if (w.invalid) return error.Invalid;
    return doc;
}

/// Byte offsets of every line start in `src` (the first is 0).
pub fn lineStarts(a: Allocator, src: []const u8) error{OutOfMemory}![]const u32 {
    var list: std.ArrayList(u32) = .empty;
    try list.append(a, 0);
    for (src, 0..) |c, i| if (c == '\n') try list.append(a, @intCast(i + 1));
    return list.toOwnedSlice(a);
}

/// The full source span of an AST node (first token start to last token end).
fn nodeSpan(ast: *const Ast, n: Ast.Node.Index) Span {
    const first = ast.firstToken(n);
    const last = ast.lastToken(n);
    return .{ .start = ast.tokenStart(first), .end = @intCast(ast.tokenStart(last) + ast.tokenSlice(last).len) };
}

const Walker = struct {
    a: Allocator,
    ast: *const Ast,
    zoir: Zoir,
    diags: *Diags,
    invalid: bool = false,

    fn nonFinite(w: *Walker, span: Span, f: f64) Kind {
        w.diags.add(span, .warning, "value is not a finite number", .{});
        return .{ .float = f };
    }

    fn node(w: *Walker, idx: Zoir.Node.Index, depth: u32) error{OutOfMemory}!Node {
        const ast_node = idx.getAstNode(w.zoir);
        const span = nodeSpan(w.ast, ast_node);
        if (depth > max_depth) {
            w.diags.add(span, .err, "nesting deeper than {d}", .{max_depth});
            w.invalid = true;
            return .{ .v = .null, .span = span };
        }
        const kind: Kind = switch (idx.get(w.zoir)) {
            .true => .{ .bool = true },
            .false => .{ .bool = false },
            .null => .null,
            .pos_inf => w.nonFinite(span, std.math.inf(f64)),
            .neg_inf => w.nonFinite(span, -std.math.inf(f64)),
            .nan => w.nonFinite(span, std.math.nan(f64)),
            .int_literal => |il| switch (il) {
                .small => |s| .{ .int = s },
                .big => |b| .{ .int = b.toInt(i64) catch {
                    w.diags.add(span, .err, "integer does not fit in 64 bits", .{});
                    w.invalid = true;
                    return .{ .v = .null, .span = span };
                } },
            },
            .float_literal => |f| .{ .float = @floatCast(f) },
            .char_literal => |c| .{ .int = c },
            .enum_literal => |s| .{ .enum_lit = try w.a.dupe(u8, s.get(w.zoir)) },
            .string_literal => |s| blk: {
                if (s.len > max_string_bytes) {
                    w.diags.add(span, .err, "string longer than {d} bytes", .{max_string_bytes});
                    w.invalid = true;
                }
                break :blk .{ .string = try w.a.dupe(u8, s) };
            },
            .empty_literal => .{ .object = &.{} },
            .array_literal => |r| blk: {
                const out = try w.a.alloc(Node, r.len);
                for (out, 0..) |*o, i| o.* = try w.node(r.at(@intCast(i)), depth + 1);
                break :blk .{ .array = out };
            },
            .struct_literal => |s| blk: {
                var out: std.ArrayList(Field) = try .initCapacity(w.a, s.names.len);
                outer: for (s.names, 0..) |name_nts, i| {
                    const name = name_nts.get(w.zoir);
                    for (out.items) |f| if (std.mem.eql(u8, f.key, name)) continue :outer;
                    const vidx = s.vals.at(@intCast(i));
                    const vast = vidx.getAstNode(w.zoir);
                    // `.name = value`: the name token is two before the value.
                    const name_tok = w.ast.firstToken(vast) - 2;
                    const key_start = w.ast.tokenStart(name_tok);
                    const key_span: Span = .{ .start = key_start, .end = @intCast(key_start + w.ast.tokenSlice(name_tok).len) };
                    out.appendAssumeCapacity(.{
                        .key = try w.a.dupe(u8, name),
                        .key_span = key_span,
                        .value = try w.node(vidx, depth + 1),
                    });
                }
                break :blk .{ .object = out.items };
            },
        };
        return .{ .v = kind, .span = span };
    }
};

/// Converts a node tree to a span-free `Value` in `arena`. Object fields are
/// sorted by key; duplicates were already dropped by the loader.
pub fn toValue(arena: Allocator, n: Node) error{OutOfMemory}!Value {
    return switch (n.v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = s },
        .enum_lit => |s| .{ .enum_lit = s },
        .array => |xs| blk: {
            const out = try arena.alloc(Value, xs.len);
            for (xs, out) |x, *o| o.* = try toValue(arena, x);
            break :blk .{ .array = out };
        },
        .object => |fs| blk: {
            const out = try arena.alloc(Value.Field, fs.len);
            for (fs, out) |f, *o| o.* = .{ .key = f.key, .value = try toValue(arena, f.value) };
            value.sortFields(out);
            break :blk .{ .object = out };
        },
    };
}

fn testLoad(src: [:0]const u8, diags: *Diags) Error!Doc {
    return loadZon(std.testing.allocator, src, diags);
}

test "zon: nested and quoted keys produce same paths" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    var doc = try testLoad(
        \\.{
        \\    // nested form
        \\    .editor = .{ .fontSize = 14 },
        \\    .@"editor.tabSize" = 2,
        \\    .@"[zig]" = .{ .@"editor.tabSize" = 4 },
        \\}
    , &d);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.items().len);
    const root = doc.root;
    try std.testing.expectEqual(@as(i64, 14), root.get("editor").?.get("fontSize").?.v.int);
    try std.testing.expectEqual(@as(i64, 2), root.get("editor.tabSize").?.v.int);
    try std.testing.expectEqual(@as(i64, 4), root.get("[zig]").?.get("editor.tabSize").?.v.int);
}

test "zon: spans round-trip to source slices" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    const src =
        \\.{
        \\    .a = "x y",
        \\    .b = .{ 1, -2, 3.5 },
        \\    .@"c.d" = .{
        \\        .e = .on,
        \\    },
        \\}
    ;
    var doc = try testLoad(src, &d);
    defer doc.deinit();
    const r = doc.root;
    try std.testing.expectEqualStrings(src, r.span.slice(src));
    try std.testing.expectEqualStrings("\"x y\"", r.get("a").?.span.slice(src));
    try std.testing.expectEqualStrings(".{ 1, -2, 3.5 }", r.get("b").?.span.slice(src));
    try std.testing.expectEqualStrings("-2", r.get("b").?.v.array[1].span.slice(src));
    try std.testing.expectEqualStrings(".on", r.get("c.d").?.get("e").?.span.slice(src));
    try std.testing.expectEqualStrings("@\"c.d\"", r.v.object[2].key_span.slice(src));
    try std.testing.expectEqualStrings("b", r.v.object[1].key_span.slice(src));
    try std.testing.expectEqual(@as(u32, 5), doc.lineCol(r.get("c.d").?.get("e").?.span.start).line);
}

test "zon: syntax error → diag line/col" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    const src = ".{\n    .a = ,\n}";
    try std.testing.expectError(error.Invalid, testLoad(src, &d));
    try std.testing.expect(d.errorCount() > 0);
    const lc = diag.lineCol(src, d.items()[0].span.start);
    try std.testing.expectEqual(@as(u32, 2), lc.line);
}

test "zon: duplicate key diag" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    var doc = try testLoad(".{ .a = 1, .a = 2 }", &d);
    defer doc.deinit();
    try std.testing.expect(d.contains("duplicate"));
    try std.testing.expectEqual(@as(usize, 1), doc.root.v.object.len);
    try std.testing.expectEqual(@as(i64, 1), doc.root.get("a").?.v.int);
}

test "zon: big int overflow diag" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    try std.testing.expectError(error.Invalid, testLoad(".{ .a = 99999999999999999999999 }", &d));
    try std.testing.expect(d.contains("64 bits"));
    var d2 = Diags.init(std.testing.allocator);
    defer d2.deinit();
    var doc = try testLoad(".{ .a = 9223372036854775807, .b = 'x' }", &d2);
    defer doc.deinit();
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), doc.root.get("a").?.v.int);
    try std.testing.expectEqual(@as(i64, 'x'), doc.root.get("b").?.v.int);
}

test "zon: comments ignored, empty literal is an empty object" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    var doc = try testLoad("// leading\n.{ .a = .{}, // trailing\n}\n", &d);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.root.get("a").?.v.object.len);
}

test "zon: toValue sorts fields" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    var doc = try testLoad(".{ .b = 1, .a = .{ true, null } }", &d);
    defer doc.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try toValue(arena.allocator(), doc.root);
    try std.testing.expectEqualStrings("a", v.object[0].key);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(".{ .a = .{ true, null }, .b = 1 }", try std.fmt.bufPrint(&buf, "{f}", .{v}));
}

test "zon: depth limit" {
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    for (0..70) |_| try src.appendSlice(std.testing.allocator, ".{ ");
    try src.append(std.testing.allocator, '1');
    for (0..70) |_| try src.appendSlice(std.testing.allocator, " }");
    const z = try std.testing.allocator.dupeZ(u8, src.items);
    defer std.testing.allocator.free(z);
    try std.testing.expectError(error.Invalid, testLoad(z, &d));
}

test "fuzz: zon_load" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const n = smith.slice(buf[0 .. buf.len - 1]);
            buf[n] = 0;
            var d = Diags.init(std.testing.allocator);
            defer d.deinit();
            var doc = loadZon(std.testing.allocator, buf[0..n :0], &d) catch return;
            doc.deinit();
        }
    }.f, .{});
}
