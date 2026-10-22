//! Evaluates a compiled `Schema` against an instance.
//!
//! - Keywords follow JSON Schema 2020-12 (core §10–11, validation §6–7).
//! - `unevaluatedProperties`/`unevaluatedItems`: each evaluation that needs
//!   them collects the property/item indices that successful subschemas
//!   evaluated (bitsets over the instance), and failed branches' marks are
//!   dropped. `anyOf` stops at the first valid branch only when nothing
//!   above needs those marks.
//! - Errors use the 2020-12 "basic" output shape. Subschemas whose failure
//!   does not fail the whole (`anyOf`, `oneOf`, `not`, `if`, `contains`)
//!   are evaluated silently, and the applicator reports one error.
//! - Every keyword evaluation is a step; past `max_steps_per_validation`,
//!   `validate` returns `error.ValidationBudgetExceeded`.
//!
//! Scratch memory (bitsets, the location stack) comes from an arena over the
//! caller's allocator, freed before returning; only `Output` keeps memory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Schema = @import("Schema.zig");
const Num = @import("number.zig").Num;
const formats = @import("formats.zig");

const NodeId = Schema.NodeId;
const Node = Schema.Node;

/// Errors from `validate` (an invalid instance is `false`, not an error).
pub const ValidateError = error{ ValidationBudgetExceeded, OutOfMemory };

/// The 2020-12 "basic" output.
pub const Output = struct {
    valid: bool = true,
    errors: std.ArrayList(Error) = .empty,
    arena: std.heap.ArenaAllocator,

    /// One failed keyword.
    pub const Error = struct {
        keyword_location: []const u8,
        absolute_keyword_location: ?[]const u8,
        /// JSON Pointer into the instance.
        instance_location: []const u8,
        message: []const u8,
    };

    /// An empty output whose strings live in an arena over `gpa`.
    pub fn init(gpa: Allocator) Output {
        return .{ .arena = .init(gpa) };
    }

    /// Frees the errors.
    pub fn deinit(self: *Output) void {
        self.arena.deinit();
    }
};

const Seg = union(enum) { key: []const u8, index: usize };

const Bits = std.DynamicBitSetUnmanaged;

const Ctx = struct {
    s: *const Schema,
    a: Allocator,
    out: ?*Output,
    collecting: bool,
    steps: u64 = 0,
    path: std.ArrayList(Seg) = .empty,
    scope: [256]u32 = undefined,
    scope_len: usize = 0,

    fn step(cx: *Ctx) ValidateError!void {
        cx.steps += 1;
        if (cx.steps > cx.s.limits.max_steps_per_validation) return error.ValidationBudgetExceeded;
    }

    fn fail(cx: *Ctx, n: *const Node, keyword: []const u8, comptime fmt: []const u8, args: anytype) ValidateError!void {
        const out = cx.out orelse return;
        if (!cx.collecting) return;
        out.valid = false;
        if (out.errors.items.len >= cx.s.limits.max_errors) return;
        const a = out.arena.allocator();
        var inst: std.ArrayList(u8) = .empty;
        for (cx.path.items) |seg| {
            try inst.append(a, '/');
            switch (seg) {
                .index => |i| try inst.print(a, "{d}", .{i}),
                .key => |k| for (k) |ch| switch (ch) {
                    '~' => try inst.appendSlice(a, "~0"),
                    '/' => try inst.appendSlice(a, "~1"),
                    else => try inst.append(a, ch),
                },
            }
        }
        const frag = n.location[(std.mem.indexOfScalar(u8, n.location, '#') orelse n.location.len)..];
        const kw = if (keyword.len == 0) "" else try std.fmt.allocPrint(a, "/{s}", .{keyword});
        try out.errors.append(a, .{
            .keyword_location = try std.fmt.allocPrint(a, "{s}{s}", .{ if (frag.len > 0) frag[1..] else "", kw }),
            .absolute_keyword_location = try std.fmt.allocPrint(a, "{s}{s}", .{ n.location, kw }),
            .instance_location = inst.items,
            .message = try std.fmt.allocPrint(a, fmt, args),
        });
    }

    /// Evaluates a subschema silently (its failure is not an error).
    fn quiet(cx: *Ctx, id: NodeId, v: Value, ev: ?*Bits) ValidateError!bool {
        const saved = cx.collecting;
        cx.collecting = false;
        defer cx.collecting = saved;
        return cx.eval(id, v, ev);
    }

    fn child(cx: *Ctx, id: NodeId, v: Value, seg: Seg) ValidateError!bool {
        try cx.path.append(cx.a, seg);
        defer _ = cx.path.pop();
        return cx.eval(id, v, null);
    }

    fn newBits(cx: *Ctx, v: Value) ValidateError!?Bits {
        const len = switch (v) {
            .object => |o| o.count(),
            .array => |arr| arr.items.len,
            else => return null,
        };
        return try Bits.initEmpty(cx.a, len);
    }

    fn eval(cx: *Ctx, id: NodeId, v: Value, ev: ?*Bits) ValidateError!bool {
        try cx.step();
        const n = &cx.s.nodes[id];
        if (n.bool_schema) |b| {
            if (!b) try cx.fail(n, "", "the false schema rejects every value", .{});
            return b;
        }
        const pushed = cx.scope_len == 0 or cx.scope[cx.scope_len - 1] != n.resource;
        if (pushed) {
            if (cx.scope_len == cx.scope.len) return error.ValidationBudgetExceeded;
            cx.scope[cx.scope_len] = n.resource;
            cx.scope_len += 1;
        }
        defer if (pushed) {
            cx.scope_len -= 1;
        };

        const ap = &n.applicators;
        const track = ev != null or ap.unevaluated_items != null or ap.unevaluated_properties != null;
        var local: ?Bits = if (track) try cx.newBits(v) else null;
        const lp: ?*Bits = if (local) |*l| l else null;
        const stop = !cx.collecting; // No errors to report: stop at the first failure.
        var valid = true;

        if (!try cx.assertions(n, v)) {
            valid = false;
            if (stop) return false;
        }
        if (ap.ref) |r| if (!try cx.eval(r, v, lp)) {
            valid = false;
            if (stop) return false;
        };
        if (ap.dynamic_ref) |d| if (!try cx.eval(cx.dynamicTarget(d), v, lp)) {
            valid = false;
            if (stop) return false;
        };
        for (ap.all_of) |s| if (!try cx.eval(s, v, lp)) {
            valid = false;
            if (stop) return false;
        };
        if (ap.any_of.len > 0) {
            var any = false;
            for (ap.any_of) |s| {
                var tmp = if (track) try cx.newBits(v) else null;
                const ok = try cx.quiet(s, v, if (tmp) |*t| t else null);
                if (ok) {
                    any = true;
                    if (tmp) |t| lp.?.setUnion(t);
                    if (!track) break;
                }
            }
            if (!any) {
                try cx.fail(n, "anyOf", "the value matches none of the anyOf subschemas", .{});
                valid = false;
                if (stop) return false;
            }
        }
        if (ap.one_of.len > 0) {
            var matched: usize = 0;
            for (ap.one_of) |s| {
                var tmp = if (track) try cx.newBits(v) else null;
                if (try cx.quiet(s, v, if (tmp) |*t| t else null)) {
                    matched += 1;
                    if (tmp) |t| lp.?.setUnion(t);
                    if (matched > 1) break;
                }
            }
            if (matched != 1) {
                try cx.fail(n, "oneOf", "the value matches {d} of the oneOf subschemas (exactly one required)", .{matched});
                valid = false;
                if (stop) return false;
            }
        }
        if (ap.not) |s| if (try cx.quiet(s, v, null)) {
            try cx.fail(n, "not", "the value matches the not subschema", .{});
            valid = false;
            if (stop) return false;
        };
        if (ap.if_) |s| {
            var tmp = if (track) try cx.newBits(v) else null;
            if (try cx.quiet(s, v, if (tmp) |*t| t else null)) {
                if (tmp) |t| lp.?.setUnion(t);
                if (ap.then_) |t| if (!try cx.eval(t, v, lp)) {
                    valid = false;
                    if (stop) return false;
                };
            } else if (ap.else_) |e| if (!try cx.eval(e, v, lp)) {
                valid = false;
                if (stop) return false;
            };
        }
        if (v == .object) {
            for (ap.dependent_schemas) |d| if (v.object.contains(d.name)) {
                if (!try cx.eval(d.node, v, lp)) {
                    valid = false;
                    if (stop) return false;
                }
            };
            if (!try cx.objectApplicators(n, v.object, lp, stop)) {
                valid = false;
                if (stop) return false;
            }
        }
        if (v == .array) {
            if (!try cx.arrayApplicators(n, v.array.items, lp, stop)) {
                valid = false;
                if (stop) return false;
            }
        }
        if (valid) {
            if (ev) |e| if (local) |l| e.setUnion(l);
        }
        return valid;
    }

    fn dynamicTarget(cx: *Ctx, d: Schema.DynRef) NodeId {
        const name = d.anchor orelse return d.static;
        // The outermost resource in the dynamic scope with that anchor wins.
        for (cx.scope[0..cx.scope_len]) |res| {
            for (cx.s.dynamic_anchors) |da| {
                if (da.resource == res and std.mem.eql(u8, da.name, name)) return da.node;
            }
        }
        return d.static;
    }

    fn objectApplicators(cx: *Ctx, n: *const Node, o: std.json.ObjectMap, lp: ?*Bits, stop: bool) ValidateError!bool {
        const ap = &n.applicators;
        var valid = true;
        const keys = o.keys();
        const vals = o.values();
        if (ap.property_names) |pn| for (keys) |k| {
            try cx.path.append(cx.a, .{ .key = k });
            defer _ = cx.path.pop();
            if (!try cx.eval(pn, .{ .string = k }, null)) {
                valid = false;
                if (stop) return false;
            }
        };
        const has_props = ap.properties.len > 0 or ap.pattern_properties.len > 0 or ap.additional_properties != null;
        if (has_props) for (keys, vals, 0..) |k, val, i| {
            var matched = false;
            for (ap.properties) |p| if (std.mem.eql(u8, p.name, k)) {
                matched = true;
                if (lp) |b| b.set(i);
                if (!try cx.child(p.node, val, .{ .key = k })) {
                    valid = false;
                    if (stop) return false;
                }
            };
            for (ap.pattern_properties) |pp| {
                const re = pp.regex orelse continue;
                const engine = cx.s.regex orelse continue;
                if (!engine.search(engine.ctx, re, k)) continue;
                matched = true;
                if (lp) |b| b.set(i);
                if (!try cx.child(pp.node, val, .{ .key = k })) {
                    valid = false;
                    if (stop) return false;
                }
            }
            if (!matched) if (ap.additional_properties) |addl| {
                if (lp) |b| b.set(i);
                if (!try cx.child(addl, val, .{ .key = k })) {
                    valid = false;
                    if (stop) return false;
                }
            };
        };
        if (ap.unevaluated_properties) |u| for (keys, vals, 0..) |k, val, i| {
            if (lp.?.isSet(i)) continue;
            lp.?.set(i);
            if (!try cx.child(u, val, .{ .key = k })) {
                valid = false;
                if (stop) return false;
            }
        };
        return valid;
    }

    fn arrayApplicators(cx: *Ctx, n: *const Node, items: []const Value, lp: ?*Bits, stop: bool) ValidateError!bool {
        const ap = &n.applicators;
        var valid = true;
        for (ap.prefix_items, 0..) |p, i| {
            if (i >= items.len) break;
            if (lp) |b| b.set(i);
            if (!try cx.child(p, items[i], .{ .index = i })) {
                valid = false;
                if (stop) return false;
            }
        }
        if (ap.items) |it| {
            var i = ap.prefix_items.len;
            while (i < items.len) : (i += 1) {
                if (lp) |b| b.set(i);
                if (!try cx.child(it, items[i], .{ .index = i })) {
                    valid = false;
                    if (stop) return false;
                }
            }
        }
        if (ap.contains) |c| {
            var matches: u64 = 0;
            for (items, 0..) |item, i| {
                try cx.path.append(cx.a, .{ .index = i });
                defer _ = cx.path.pop();
                if (try cx.quiet(c, item, null)) {
                    matches += 1;
                    if (lp) |b| b.set(i);
                }
            }
            const min = n.min_contains orelse 1;
            if (matches < min) {
                try cx.fail(n, "contains", "{d} items match contains; at least {d} required", .{ matches, min });
                valid = false;
                if (stop) return false;
            }
            if (n.max_contains) |max| if (matches > max) {
                try cx.fail(n, "maxContains", "{d} items match contains; at most {d} allowed", .{ matches, max });
                valid = false;
                if (stop) return false;
            };
        }
        if (ap.unevaluated_items) |u| for (items, 0..) |item, i| {
            if (lp.?.isSet(i)) continue;
            lp.?.set(i);
            if (!try cx.child(u, item, .{ .index = i })) {
                valid = false;
                if (stop) return false;
            }
        };
        return valid;
    }

    /// The validation vocabulary. Returns false on the first failure when
    /// not collecting errors.
    fn assertions(cx: *Ctx, n: *const Node, v: Value) ValidateError!bool {
        var valid = true;
        const stop = !cx.collecting;
        if (!n.types.isAny() and !n.types.matches(v)) {
            try cx.step();
            try cx.fail(n, "type", "the value has the wrong type", .{});
            valid = false;
            if (stop) return false;
        }
        if (n.const_value) |c| if (!equal(c, v)) {
            try cx.step();
            try cx.fail(n, "const", "the value differs from const", .{});
            valid = false;
            if (stop) return false;
        };
        if (n.enum_values) |vals| {
            try cx.step();
            const found = for (vals) |e| {
                if (equal(e, v)) break true;
            } else false;
            if (!found) {
                try cx.fail(n, "enum", "the value is not one of the enum values", .{});
                valid = false;
                if (stop) return false;
            }
        }
        switch (v) {
            .integer, .float, .number_string => if (Num.fromValue(v)) |x| {
                if (!try cx.numeric(n, x)) {
                    valid = false;
                    if (stop) return false;
                }
            },
            .string => |s| if (!try cx.string(n, s)) {
                valid = false;
                if (stop) return false;
            },
            .array => |arr| if (!try cx.array(n, arr.items)) {
                valid = false;
                if (stop) return false;
            },
            .object => |o| if (!try cx.object(n, o)) {
                valid = false;
                if (stop) return false;
            },
            else => {},
        }
        return valid;
    }

    fn numeric(cx: *Ctx, n: *const Node, x: Num) ValidateError!bool {
        var valid = true;
        if (n.multiple_of) |m| if (!x.multipleOf(m)) {
            try cx.fail(n, "multipleOf", "the value is not a multiple of the divisor", .{});
            valid = false;
        };
        if (n.maximum) |m| if (x.order(m) == .gt) {
            try cx.fail(n, "maximum", "the value exceeds the maximum", .{});
            valid = false;
        };
        if (n.exclusive_maximum) |m| if (x.order(m) != .lt) {
            try cx.fail(n, "exclusiveMaximum", "the value is not below the exclusive maximum", .{});
            valid = false;
        };
        if (n.minimum) |m| if (x.order(m) == .lt) {
            try cx.fail(n, "minimum", "the value is below the minimum", .{});
            valid = false;
        };
        if (n.exclusive_minimum) |m| if (x.order(m) != .gt) {
            try cx.fail(n, "exclusiveMinimum", "the value is not above the exclusive minimum", .{});
            valid = false;
        };
        return valid;
    }

    fn string(cx: *Ctx, n: *const Node, s: []const u8) ValidateError!bool {
        var valid = true;
        if (n.max_length != null or n.min_length != null) {
            const len = std.unicode.utf8CountCodepoints(s) catch {
                try cx.fail(n, "minLength", "the string is not valid UTF-8", .{});
                return false;
            };
            if (n.max_length) |m| if (len > m) {
                try cx.fail(n, "maxLength", "the string has {d} characters; at most {d} allowed", .{ len, m });
                valid = false;
            };
            if (n.min_length) |m| if (len < m) {
                try cx.fail(n, "minLength", "the string has {d} characters; at least {d} required", .{ len, m });
                valid = false;
            };
        }
        if (n.pattern) |re| if (cx.s.regex) |engine| if (!engine.search(engine.ctx, re, s)) {
            try cx.fail(n, "pattern", "the string does not match /{s}/", .{n.pattern_src.?});
            valid = false;
        };
        if (n.format) |f| if (!formats.check(cx.s.format_assertion, f, s)) {
            try cx.fail(n, "format", "the string is not a valid {s}", .{f});
            valid = false;
        };
        return valid;
    }

    fn array(cx: *Ctx, n: *const Node, items: []const Value) ValidateError!bool {
        var valid = true;
        if (n.max_items) |m| if (items.len > m) {
            try cx.fail(n, "maxItems", "the array has {d} items; at most {d} allowed", .{ items.len, m });
            valid = false;
        };
        if (n.min_items) |m| if (items.len < m) {
            try cx.fail(n, "minItems", "the array has {d} items; at least {d} required", .{ items.len, m });
            valid = false;
        };
        if (n.unique_items and items.len > 1) {
            if (try cx.duplicate(items)) |pair| {
                try cx.fail(n, "uniqueItems", "items {d} and {d} are equal", .{ pair[0], pair[1] });
                valid = false;
            }
        }
        return valid;
    }

    /// The first pair of equal items: canonical hashes, sorted, then deep
    /// comparison within equal-hash runs. O(n log n).
    fn duplicate(cx: *Ctx, items: []const Value) ValidateError!?[2]usize {
        const Entry = struct { h: u64, i: usize };
        const es = try cx.a.alloc(Entry, items.len);
        for (items, es, 0..) |item, *e, i| e.* = .{ .h = hash(item), .i = i };
        std.mem.sort(Entry, es, {}, struct {
            fn lt(_: void, x: Entry, y: Entry) bool {
                return x.h < y.h or (x.h == y.h and x.i < y.i);
            }
        }.lt);
        var start: usize = 0;
        while (start < es.len) {
            var end = start + 1;
            while (end < es.len and es[end].h == es[start].h) end += 1;
            for (es[start..end], start..) |x, xi| for (es[xi + 1 .. end]) |y| {
                if (equal(items[x.i], items[y.i])) return .{ @min(x.i, y.i), @max(x.i, y.i) };
            };
            start = end;
        }
        return null;
    }

    fn object(cx: *Ctx, n: *const Node, o: std.json.ObjectMap) ValidateError!bool {
        var valid = true;
        const c = o.count();
        if (n.max_properties) |m| if (c > m) {
            try cx.fail(n, "maxProperties", "the object has {d} properties; at most {d} allowed", .{ c, m });
            valid = false;
        };
        if (n.min_properties) |m| if (c < m) {
            try cx.fail(n, "minProperties", "the object has {d} properties; at least {d} required", .{ c, m });
            valid = false;
        };
        for (n.required) |r| if (!o.contains(r)) {
            try cx.fail(n, "required", "required property \"{s}\" is missing", .{r});
            valid = false;
        };
        for (n.dependent_required) |d| if (o.contains(d.name)) {
            for (d.required) |r| if (!o.contains(r)) {
                try cx.fail(n, "dependentRequired", "property \"{s}\" requires \"{s}\"", .{ d.name, r });
                valid = false;
            };
        };
        return valid;
    }
};

/// JSON equality: numbers compare mathematically, object key order is
/// irrelevant.
pub fn equal(a: Value, b: Value) bool {
    const na = Num.fromValue(a);
    const nb = Num.fromValue(b);
    if (na != null or nb != null) {
        if (na == null or nb == null) return false;
        return na.?.eql(nb.?);
    }
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| b == .array and x.items.len == b.array.items.len and for (x.items, b.array.items) |p, q| {
            if (!equal(p, q)) break false;
        } else true,
        .object => |x| b == .object and x.count() == b.object.count() and blk: {
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!equal(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// A hash consistent with `equal`.
fn hash(v: Value) u64 {
    var h = std.hash.Wyhash.init(0);
    hashInto(&h, v);
    return h.final();
}

fn hashInto(h: *std.hash.Wyhash, v: Value) void {
    if (Num.fromValue(v)) |n| {
        h.update("n");
        h.update(std.mem.asBytes(&n.neg));
        h.update(std.mem.asBytes(&n.mant));
        h.update(std.mem.asBytes(&n.exp));
        return;
    }
    switch (v) {
        .null => h.update("z"),
        .bool => |b| h.update(if (b) "t" else "f"),
        .string => |s| {
            h.update("s");
            h.update(s);
            h.update("\x00");
        },
        .array => |arr| {
            h.update("[");
            for (arr.items) |e| hashInto(h, e);
            h.update("]");
        },
        .object => |o| {
            // Order-independent: combine member hashes commutatively.
            var acc: u64 = 0;
            var it = o.iterator();
            while (it.next()) |e| {
                var m = std.hash.Wyhash.init(1);
                m.update(e.key_ptr.*);
                m.update("\x00");
                hashInto(&m, e.value_ptr.*);
                acc +%= m.final();
            }
            h.update("{");
            h.update(std.mem.asBytes(&acc));
        },
        else => {},
    }
}

/// Validates `instance` against `s`. With `out`, collects errors there.
pub fn validate(s: *const Schema, gpa: Allocator, instance: Value, out: ?*Output) ValidateError!bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var cx: Ctx = .{ .s = s, .a = arena.allocator(), .out = out, .collecting = out != null };
    const ok = try cx.eval(s.root, instance, null);
    if (out) |o| o.valid = ok;
    return ok;
}
