//! Context references and resolved context items, aligned with E08.F08
//! (`ContextRef`/`ContextItem`; E08 re-exports these).

const std = @import("std");

/// What a piece of context refers to.
pub const ContextRef = union(enum) {
    file: []const u8,
    range: struct { path: []const u8, lines: [2]u32 },
    folder: []const u8,
    note: struct { target: []const u8, depth: u8 = 0 },
    symbol: []const u8,
    search: []const u8,
    tag: []const u8,
    selection: struct { doc: u64, range: [2]u64 },
    terminal: struct { terminal: u64, block: ?u64 = null },
    url: []const u8,
    scm_diff: []const u8,

    /// JSON form: `{"type":"<kind>","value":"..."}` for string kinds,
    /// `{"type":"<kind>", <fields>...}` for struct kinds.
    pub fn jsonStringify(r: ContextRef, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("type");
        try jws.write(@tagName(r));
        switch (r) {
            inline else => |payload| {
                const P = @TypeOf(payload);
                if (P == []const u8) {
                    try jws.objectField("value");
                    try jws.write(payload);
                } else inline for (std.meta.fields(P)) |f| {
                    try jws.objectField(f.name);
                    try jws.write(@field(payload, f.name));
                }
            },
        }
        try jws.endObject();
    }

    /// Inverse of `jsonStringify`.
    pub fn jsonParseFromValue(a: std.mem.Allocator, v: std.json.Value, opts: std.json.ParseOptions) std.json.ParseFromValueError!ContextRef {
        if (v != .object) return error.UnexpectedToken;
        const ty = v.object.get("type") orelse return error.MissingField;
        if (ty != .string) return error.UnexpectedToken;
        inline for (std.meta.fields(ContextRef)) |f| {
            if (std.mem.eql(u8, f.name, ty.string)) {
                if (f.type == []const u8) {
                    const val = v.object.get("value") orelse return error.MissingField;
                    if (val != .string) return error.UnexpectedToken;
                    return @unionInit(ContextRef, f.name, val.string);
                }
                var o = opts;
                o.ignore_unknown_fields = true; // the "type" member
                return @unionInit(ContextRef, f.name, try std.json.innerParseFromValue(f.type, a, v, o));
            }
        }
        return error.InvalidEnumTag;
    }
};

/// A resolved context reference ready to put in a prompt.
pub const ContextItem = struct {
    ref: ContextRef,
    title: []const u8,
    mime: []const u8,
    text: []const u8,
    tokens: u32,
    /// Hash of the source version; lets the assembler skip unchanged items.
    version_hash: u64,
    truncated: bool = false,
    /// Names of parts left out (e.g. files of a folder over budget).
    omitted: []const []const u8 = &.{},
};
