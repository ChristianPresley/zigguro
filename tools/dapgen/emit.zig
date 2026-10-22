//! Emits `packages/dap/src/gen/protocol.zig` from the DAP JSON schema.
//!
//! Mapping rules (see E07.F06.S01.T03):
//! - `integer` -> i64 (adapter ids can exceed i32), `number` -> f64,
//!   `boolean` -> bool, `string` -> []const u8;
//! - `allOf` definitions (every request, response and event) are flattened
//!   into one struct, base properties first;
//! - a property with a single-value `enum` (`command`, `event`, `type`) is
//!   a literal: the value is its default and it is listed in
//!   `json_literals`;
//! - other `enum`s become closed Zig enums with an `_unknown` member that
//!   absorbs values the schema does not list; `_enum` (suggested values)
//!   becomes `json.OpenEnum`, keeping unknown strings;
//! - `["T", "null"]` is `?T`; the any-type list is `std.json.Value`; other
//!   type lists and `oneOf` become a `union(enum)`;
//! - `object` with `additionalProperties` is `std.json.ArrayHashMap(V)`; an
//!   inline `object` with properties gets a synthesized struct named after
//!   its owner and property (`StoppedEventBody`), and one without any is
//!   `std.json.Value`;
//! - properties not in `required` are `?T = null` and omitted when null.
//!
//! The command and event tables (`Command`, `RequestInfo`, `EventKind`,
//! `EventBody`, `ReverseCommand`) are derived from the single-value `enum`
//! on each message's `command` or `event` property; reverse requests are
//! the requests in the "Reverse Requests" group (sent from the debug
//! adapter to the client). Declarations are sorted by name
//! and the output is rendered through `std.zig.Ast`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const schema = @import("schema.zig");
const Schema = schema.Schema;
const Property = schema.Property;

/// Generation options.
pub const Options = struct {
    /// File name recorded in the header comment.
    source_name: []const u8 = "debugAdapterProtocol.json",
};

/// Emission failures.
pub const Error = error{ OutOfMemory, Unsupported, InvalidOutput };

const Decl = struct { name: []const u8, text: []const u8 };

const MessageKind = enum { request, response, event };

/// One request or event, for the method tables.
const Message = struct {
    /// Wire name (`initialize`, `stopped`).
    name: []const u8,
    /// Definition name (`InitializeRequest`, `StoppedEvent`).
    def: []const u8,
    reverse: bool,
};

/// Returns the formatted Zig source for `doc`. `bytes` is the schema file,
/// hashed into `schema_sha256`.
pub fn emit(arena: Allocator, doc: *const schema.Document, bytes: []const u8, opts: Options) Error![]const u8 {
    var e: Emitter = .{ .arena = arena, .doc = doc };
    for (doc.definitions) |d| try e.names.put(arena, d.name, {});
    for ([_][]const u8{ "std", "json", "Command", "RequestInfo", "command_names", "EventKind", "EventBody", "event_names", "ReverseCommand", "reverse_command_names", "schema_sha256" }) |r| try e.names.put(arena, r, {});
    return e.run(bytes, opts);
}

const Emitter = struct {
    arena: Allocator,
    doc: *const schema.Document,
    names: std.StringHashMapUnmanaged(void) = .empty,
    /// Synthesized type names by hint, so a type is emitted once.
    synth: std.StringHashMapUnmanaged([]const u8) = .empty,
    decls: std.ArrayList(Decl) = .empty,

    fn unique(e: *Emitter, base: []const u8) Error![]const u8 {
        if (!e.names.contains(base)) {
            try e.names.put(e.arena, base, {});
            return base;
        }
        var n: usize = 2;
        while (true) : (n += 1) {
            const cand = try std.fmt.allocPrint(e.arena, "{s}{d}", .{ base, n });
            if (!e.names.contains(cand)) {
                try e.names.put(e.arena, cand, {});
                return cand;
            }
        }
    }

    fn addDecl(e: *Emitter, name: []const u8, text: []const u8) Error!void {
        try e.decls.append(e.arena, .{ .name = name, .text = text });
    }

    fn baseOf(s: Schema) ?[]const u8 {
        if (s.all_of.len == 0) return null;
        return s.all_of[0].ref;
    }

    /// The flattened properties and required list of an `allOf` schema or
    /// a definition reference.
    fn flatten(e: *Emitter, s: Schema, props: *std.ArrayList(Property), required: *std.ArrayList([]const u8)) Error!void {
        if (s.ref) |r| {
            const target = e.doc.get(r) orelse return error.Unsupported;
            return e.flatten(target.*, props, required);
        }
        for (s.all_of) |part| try e.flatten(part, props, required);
        for (s.properties) |p| {
            for (props.items) |*q| {
                if (std.mem.eql(u8, q.name, p.name)) {
                    q.* = p;
                    break;
                }
            } else try props.append(e.arena, p);
        }
        for (s.required) |r| {
            for (required.items) |q| {
                if (std.mem.eql(u8, q, r)) break;
            } else try required.append(e.arena, r);
        }
    }

    // ------------------------------------------------------------- types

    fn typeExpr(e: *Emitter, s: Schema, hint: []const u8, owner: ?[]const u8) Error![]const u8 {
        if (s.ref) |r| {
            if (e.doc.get(r) == null) {
                std.log.err("dapgen: unknown reference {s}", .{r});
                return error.Unsupported;
            }
            if (owner) |o| if (std.mem.eql(u8, o, r)) return try std.fmt.allocPrint(e.arena, "*const {s}", .{r});
            return r;
        }
        if (s.one_of.len > 0) return e.unionOf(s.one_of, hint, owner);
        if (s.all_of.len > 0) return e.synthStruct(s, hint);
        // Type lists: strip null, then map what is left.
        var rest: std.ArrayList([]const u8) = .empty;
        var nullable = false;
        for (s.types) |t| {
            if (std.mem.eql(u8, t, "null")) nullable = true else try rest.append(e.arena, t);
        }
        if (rest.items.len == 0) return if (nullable) "void" else "std.json.Value";
        if (rest.items.len >= 5) return "std.json.Value";
        const opt: []const u8 = if (nullable) "?" else "";
        if (rest.items.len > 1) {
            var alts: std.ArrayList(Schema) = .empty;
            for (rest.items) |t| {
                const one = try e.arena.alloc([]const u8, 1);
                one[0] = t;
                var alt = s;
                alt.types = one;
                try alts.append(e.arena, alt);
            }
            return cat(e.arena, opt, try e.unionOf(alts.items, hint, owner));
        }
        const t = rest.items[0];
        const inner: []const u8 = if (std.mem.eql(u8, t, "string")) blk: {
            if (s.enum_values) |vals| {
                if (vals.len == 1) break :blk "[]const u8";
                break :blk try e.synthEnum(vals, false, hint, s.description);
            }
            if (s.open_enum) |vals| break :blk try e.synthEnum(vals, true, hint, s.description);
            break :blk "[]const u8";
        } else if (std.mem.eql(u8, t, "integer"))
            "i64"
        else if (std.mem.eql(u8, t, "number"))
            "f64"
        else if (std.mem.eql(u8, t, "boolean"))
            "bool"
        else if (std.mem.eql(u8, t, "array")) blk: {
            const item = s.items orelse break :blk "[]const std.json.Value";
            break :blk try std.fmt.allocPrint(e.arena, "[]const {s}", .{try e.typeExpr(item.*, try cat(e.arena, hint, "Item"), null)});
        } else if (std.mem.eql(u8, t, "object")) blk: {
            if (s.additional_properties) |ap| {
                break :blk try std.fmt.allocPrint(e.arena, "std.json.ArrayHashMap({s})", .{try e.typeExpr(ap.*, try cat(e.arena, hint, "Value"), null)});
            }
            if (s.properties.len == 0) break :blk "std.json.Value";
            break :blk try e.synthStruct(s, hint);
        } else {
            std.log.err("dapgen: unknown type {s} in {s}", .{ t, hint });
            return error.Unsupported;
        };
        return cat(e.arena, opt, inner);
    }

    fn synthStruct(e: *Emitter, s: Schema, hint: []const u8) Error![]const u8 {
        if (e.synth.get(hint)) |n| return n;
        const name = try e.unique(hint);
        try e.synth.put(e.arena, hint, name);
        try e.emitStruct(name, s, null);
        return name;
    }

    fn synthEnum(e: *Emitter, vals: []const []const u8, open: bool, hint: []const u8, doc: ?[]const u8) Error![]const u8 {
        if (e.synth.get(hint)) |n| return n;
        const name = try e.unique(hint);
        try e.synth.put(e.arena, hint, name);
        try e.emitEnum(name, vals, open, doc);
        return name;
    }

    fn unionOf(e: *Emitter, alts: []const Schema, hint: []const u8, owner: ?[]const u8) Error![]const u8 {
        if (e.synth.get(hint)) |n| return n;
        const name = try e.unique(hint);
        try e.synth.put(e.arena, hint, name);
        var body: std.ArrayList(u8) = .empty;
        for (alts) |alt| {
            const fname = if (alt.ref) |r| try snake(e.arena, r) else if (alt.types.len == 1) alt.types[0] else "value";
            const ftype = try e.typeExpr(alt, try cat(e.arena, name, try pascal(e.arena, fname)), owner);
            try body.print(e.arena, "{f}: {s},\n", .{ std.zig.fmtId(fname), ftype });
        }
        try e.addDecl(name, try std.fmt.allocPrint(e.arena,
            \\pub const {s} = union(enum) {{
            \\{s}
            \\pub const json_any_of = true;
            \\pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {{
            \\    return json.parseUnion(@This(), a, source, options);
            \\}}
            \\pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, options: std.json.ParseOptions) !@This() {{
            \\    return json.parseUnionFromValue(@This(), a, v, options);
            \\}}
            \\pub fn jsonStringify(self: @This(), w: *std.json.Stringify) std.json.Stringify.Error!void {{
            \\    return json.writeUnion(self, w);
            \\}}
            \\}};
        , .{ name, body.items }));
        return name;
    }

    // ------------------------------------------------------------- decls

    fn emitStruct(e: *Emitter, name: []const u8, s: Schema, doc_override: ?[]const u8) Error!void {
        var props: std.ArrayList(Property) = .empty;
        var required: std.ArrayList([]const u8) = .empty;
        try e.flatten(s, &props, &required);
        var body: std.ArrayList(u8) = .empty;
        var literals: std.ArrayList([]const u8) = .empty;
        var nullable: std.ArrayList([]const u8) = .empty;
        for (props.items) |p| {
            const req = for (required.items) |r| {
                if (std.mem.eql(u8, r, p.name)) break true;
            } else false;
            try writeDoc(e.arena, &body, p.schema.description);
            const fid = std.zig.fmtId(p.name);
            if (p.schema.enum_values) |vals| if (vals.len == 1 and p.schema.ref == null) {
                if (req) {
                    try body.print(e.arena, "{f}: []const u8 = \"{f}\",\n", .{ fid, std.zig.fmtString(vals[0]) });
                    try literals.append(e.arena, p.name);
                } else try body.print(e.arena, "{f}: ?[]const u8 = null,\n", .{fid});
                continue;
            };
            const inner = try e.typeExpr(p.schema, try cat(e.arena, name, try pascal(e.arena, p.name)), name);
            const is_opt = inner[0] == '?';
            if (!req) {
                try body.print(e.arena, "{f}: {s}{s} = null,\n", .{ fid, if (is_opt) "" else "?", inner });
            } else if (is_opt) {
                try body.print(e.arena, "{f}: {s} = null,\n", .{ fid, inner });
                try nullable.append(e.arena, p.name);
            } else {
                try body.print(e.arena, "{f}: {s},\n", .{ fid, inner });
            }
        }
        var text: std.ArrayList(u8) = .empty;
        try writeDoc(e.arena, &text, doc_override orelse e.structDoc(s));
        try text.print(e.arena, "pub const {f} = struct {{\n{s}", .{ std.zig.fmtId(name), body.items });
        if (literals.items.len > 0) {
            try text.appendSlice(e.arena, "/// Properties fixed to a literal value (used to tell union alternatives apart).\npub const json_literals: []const []const u8 = &.{");
            for (literals.items) |l| try text.print(e.arena, "\"{f}\",", .{std.zig.fmtString(l)});
            try text.appendSlice(e.arena, "};\n");
        }
        try text.appendSlice(e.arena, "pub fn jsonStringify(self: @This(), w: *std.json.Stringify) std.json.Stringify.Error!void {\nreturn json.writeStruct(self, w, &.{");
        for (nullable.items) |l| try text.print(e.arena, "\"{f}\",", .{std.zig.fmtString(l)});
        try text.appendSlice(e.arena, "});\n}\n};");
        try e.addDecl(name, text.items);
    }

    /// The description of an `allOf` definition lives on its second part.
    fn structDoc(e: *Emitter, s: Schema) ?[]const u8 {
        _ = e;
        if (s.description) |d| return d;
        for (s.all_of) |part| if (part.description) |d| return d;
        return null;
    }

    fn emitEnum(e: *Emitter, name: []const u8, vals: []const []const u8, open: bool, doc: ?[]const u8) Error!void {
        var body: std.ArrayList(u8) = .empty;
        for (vals) |v| try body.print(e.arena, "{f},\n", .{std.zig.fmtIdFlags(v, .{ .allow_primitive = true, .allow_underscore = true })});
        var text: std.ArrayList(u8) = .empty;
        try writeDoc(e.arena, &text, doc);
        if (open) {
            try text.print(e.arena, "pub const {s} = json.OpenEnum(enum {{\n{s}}});", .{ name, body.items });
        } else {
            try text.print(e.arena,
                \\pub const {s} = enum {{
                \\{s}/// A value this schema version does not list.
                \\_unknown,
                \\pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {{
                \\    return json.parseStringEnum(@This(), a, source, options);
                \\}}
                \\pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, options: std.json.ParseOptions) !@This() {{
                \\    return json.parseStringEnumFromValue(@This(), a, v, options);
                \\}}
                \\pub fn jsonStringify(self: @This(), w: *std.json.Stringify) std.json.Stringify.Error!void {{
                \\    return json.writeStringEnum(self, w);
                \\}}
                \\}};
            , .{ name, body.items });
        }
        try e.addDecl(name, text.items);
    }

    fn emitDefinition(e: *Emitter, d: schema.Definition) Error!void {
        const s = d.schema;
        if (s.all_of.len > 0 or s.properties.len > 0 or (s.hasType("object") and s.additional_properties == null and s.types.len == 1)) {
            try e.synth.put(e.arena, d.name, d.name);
            return e.emitStruct(d.name, s, null);
        }
        if (s.hasType("string") and s.types.len == 1) {
            if (s.enum_values) |vals| return e.emitEnum(d.name, vals, false, s.description);
            if (s.open_enum) |vals| return e.emitEnum(d.name, vals, true, s.description);
        }
        var text: std.ArrayList(u8) = .empty;
        try writeDoc(e.arena, &text, s.description);
        try text.print(e.arena, "pub const {s} = {s};", .{ d.name, try e.typeExpr(s, d.name, d.name) });
        try e.addDecl(d.name, text.items);
    }

    // ------------------------------------------------------------- tables

    /// The single `enum` value of property `prop` in a message definition.
    fn messageName(s: Schema, prop: []const u8) ?[]const u8 {
        for (s.all_of[1..]) |part| for (part.properties) |p| {
            if (!std.mem.eql(u8, p.name, prop)) continue;
            const vals = p.schema.enum_values orelse return null;
            if (vals.len == 1) return vals[0];
        };
        return null;
    }

    /// The type of property `prop` of message definition `def`, or `void`.
    fn payloadType(e: *Emitter, def: []const u8, prop: []const u8) Error![]const u8 {
        const s = e.doc.get(def) orelse return "void";
        var props: std.ArrayList(Property) = .empty;
        var required: std.ArrayList([]const u8) = .empty;
        try e.flatten(s.*, &props, &required);
        for (props.items) |p| {
            if (!std.mem.eql(u8, p.name, prop)) continue;
            // The generic Request/Response/Event payload is "any"; a message
            // that does not narrow it carries no payload.
            if (p.schema.ref == null and p.schema.types.len >= 5) return "void";
            const t = try e.typeExpr(p.schema, try cat(e.arena, def, try pascal(e.arena, prop)), def);
            return if (t[0] == '?') t[1..] else t;
        }
        return "void";
    }

    fn run(e: *Emitter, bytes: []const u8, opts: Options) Error![]const u8 {
        var defs: std.ArrayList(schema.Definition) = .empty;
        try defs.appendSlice(e.arena, e.doc.definitions);
        std.mem.sort(schema.Definition, defs.items, {}, struct {
            fn lt(_: void, a: schema.Definition, b: schema.Definition) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        for (defs.items) |d| try e.emitDefinition(d);

        var requests: std.ArrayList(Message) = .empty;
        var events: std.ArrayList(Message) = .empty;
        for (defs.items) |d| {
            const base = baseOf(d.schema) orelse continue;
            if (std.mem.eql(u8, base, "Request")) {
                const name = messageName(d.schema, "command") orelse continue;
                // The schema titles only the first reverse request; the rest
                // say so in their description.
                const reverse = for (d.schema.all_of[1..]) |p| {
                    if (p.title) |t| if (std.mem.eql(u8, t, "Reverse Requests")) break true;
                    if (p.description) |desc| if (std.mem.indexOf(u8, desc, "sent from the debug adapter to the client") != null) break true;
                } else false;
                try requests.append(e.arena, .{ .name = name, .def = d.name, .reverse = reverse });
            } else if (std.mem.eql(u8, base, "Event")) {
                const name = messageName(d.schema, "event") orelse continue;
                try events.append(e.arena, .{ .name = name, .def = d.name, .reverse = false });
            }
        }
        const byName = struct {
            fn lt(_: void, a: Message, b: Message) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt;
        std.mem.sort(Message, requests.items, {}, byName);
        std.mem.sort(Message, events.items, {}, byName);

        var tables: std.ArrayList(u8) = .empty;
        const a = e.arena;
        // Commands.
        try tables.appendSlice(a, "/// Every request command in the protocol; `_unknown` stands for any other.\npub const Command = enum {\n");
        for (requests.items) |r| try tables.print(a, "{f},\n", .{std.zig.fmtIdFlags(r.name, .{ .allow_primitive = true, .allow_underscore = true })});
        try tables.appendSlice(a, "_unknown,\n};\n\n");
        try tables.appendSlice(a,
            \\/// The argument and response-body types of a request, and whether the
            \\/// adapter sends it to the client (a reverse request).
            \\pub fn RequestInfo(comptime c: Command) type {
            \\    return switch (c) {
            \\
        );
        for (requests.items) |r| {
            const resp_def = try std.fmt.allocPrint(a, "{s}Response", .{r.def[0 .. r.def.len - "Request".len]});
            try tables.print(a, ".{f} => struct {{\npub const RequestType = {s};\npub const Arguments = {s};\npub const ResponseBody = {s};\npub const reverse = {};\n}},\n", .{
                std.zig.fmtIdFlags(r.name, .{ .allow_primitive = true, .allow_underscore = true }),
                r.def,
                try e.payloadType(r.def, "arguments"),
                try e.payloadType(resp_def, "body"),
                r.reverse,
            });
        }
        try tables.appendSlice(a, "._unknown => struct {\npub const RequestType = Request;\npub const Arguments = std.json.Value;\npub const ResponseBody = std.json.Value;\npub const reverse = false;\n},\n};\n}\n\n");
        try tables.appendSlice(a, "/// Looks up a command by its wire name.\npub const command_names = std.StaticStringMap(Command).initComptime(.{\n");
        for (requests.items) |r| try tables.print(a, ".{{ \"{f}\", .{f} }},\n", .{ std.zig.fmtString(r.name), std.zig.fmtIdFlags(r.name, .{ .allow_primitive = true, .allow_underscore = true }) });
        try tables.appendSlice(a, "});\n\n");

        // Reverse requests.
        try tables.appendSlice(a, "/// Requests the adapter sends to the client; `_unknown` stands for any other.\npub const ReverseCommand = enum {\n");
        for (requests.items) |r| if (r.reverse) try tables.print(a, "{f},\n", .{std.zig.fmtId(r.name)});
        try tables.appendSlice(a, "_unknown,\n};\n\n");
        try tables.appendSlice(a, "/// Looks up a reverse request by its wire name.\npub const reverse_command_names = std.StaticStringMap(ReverseCommand).initComptime(.{\n");
        for (requests.items) |r| if (r.reverse) try tables.print(a, ".{{ \"{f}\", .{f} }},\n", .{ std.zig.fmtString(r.name), std.zig.fmtId(r.name) });
        try tables.appendSlice(a, "});\n\n");

        // Events.
        try tables.appendSlice(a, "/// Every event in the protocol; `_unknown` stands for any other.\npub const EventKind = enum {\n");
        for (events.items) |ev| try tables.print(a, "{f},\n", .{std.zig.fmtIdFlags(ev.name, .{ .allow_primitive = true, .allow_underscore = true })});
        try tables.appendSlice(a, "_unknown,\n};\n\n");
        try tables.appendSlice(a, "/// The body type of an event.\npub fn EventBody(comptime k: EventKind) type {\n    return switch (k) {\n");
        for (events.items) |ev| {
            try tables.print(a, ".{f} => {s},\n", .{ std.zig.fmtIdFlags(ev.name, .{ .allow_primitive = true, .allow_underscore = true }), try e.payloadType(ev.def, "body") });
        }
        try tables.appendSlice(a, "._unknown => std.json.Value,\n};\n}\n\n");
        try tables.appendSlice(a, "/// Looks up an event by its wire name.\npub const event_names = std.StaticStringMap(EventKind).initComptime(.{\n");
        for (events.items) |ev| try tables.print(a, ".{{ \"{f}\", .{f} }},\n", .{ std.zig.fmtString(ev.name), std.zig.fmtIdFlags(ev.name, .{ .allow_primitive = true, .allow_underscore = true }) });
        try tables.appendSlice(a, "});\n\n");

        std.mem.sort(Decl, e.decls.items, {}, struct {
            fn lt(_: void, x: Decl, y: Decl) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var src: std.ArrayList(u8) = .empty;
        try src.print(a,
            \\//! Debug Adapter Protocol types. Generated by `tools/dapgen` from
            \\//! `tools/dapgen/data/{s}`; do not edit. Regenerate with `zig build dapgen`.
            \\
            \\const std = @import("std");
            \\const json = @import("../proto/json.zig");
            \\
            \\/// SHA-256 of the schema these types were generated from.
            \\pub const schema_sha256 = "{x}";
            \\
            \\
        , .{ opts.source_name, &digest });
        try src.appendSlice(a, tables.items);
        for (e.decls.items) |d| {
            try src.appendSlice(a, d.text);
            try src.appendSlice(a, "\n\n");
        }
        return format(a, src.items);
    }
};

/// Writes the first paragraph of `doc` as `///` lines.
fn writeDoc(arena: Allocator, out: *std.ArrayList(u8), doc: ?[]const u8) Error!void {
    const d = doc orelse return;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, d, " \n\r\t"), '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \r\t");
        if (l.len == 0) break;
        try out.print(arena, "/// {s}\n", .{l});
    }
}

/// Parses and re-renders `src` in canonical `zig fmt` style.
pub fn format(arena: Allocator, src: []const u8) Error![]const u8 {
    const z = try arena.dupeZ(u8, src);
    var tree = try std.zig.Ast.parse(arena, z, .zig);
    if (tree.errors.len > 0) {
        for (tree.errors) |pe| {
            const loc = tree.tokenLocation(0, pe.token);
            std.log.err("dapgen: generated source does not parse at {d}:{d} ({t}): {s}", .{ loc.line + 1, loc.column + 1, pe.tag, z[loc.line_start..loc.line_end] });
        }
        return error.InvalidOutput;
    }
    return tree.renderAlloc(arena);
}

fn cat(arena: Allocator, a: []const u8, b: []const u8) Error![]const u8 {
    return std.mem.concat(arena, u8, &.{ a, b });
}

/// `body` -> `Body`, `__restart` -> `Restart`.
pub fn pascal(arena: Allocator, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var up = true;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            up = true;
            continue;
        }
        try out.append(arena, if (up) std.ascii.toUpper(c) else c);
        up = false;
    }
    return out.items;
}

/// `LaunchRequestArguments` -> `launch_request_arguments`.
pub fn snake(arena: Allocator, s: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0 and std.ascii.isLower(s[i - 1])) try out.append(arena, '_');
            try out.append(arena, std.ascii.toLower(c));
        } else try out.append(arena, c);
    }
    return out.items;
}
