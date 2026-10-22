//! Headless elicitation models (E11.F03.S03.T02) for the host's input UI:
//!
//! - `FormModel`: a form-mode request's restricted schema (ELICIT
//!   "Requested Schema") compiled into fields, with defaults, validation
//!   through the JSON Schema validator (formats asserted) and a warning
//!   when a field looks like a secret, which servers must not ask for in
//!   form mode. Anything beyond a flat object of primitive properties is
//!   `UnsupportedSchema`: the broker declines rather than render half a
//!   form.
//! - `UrlConsent`: what to show before opening a URL-mode page (ELICIT
//!   "Safe URL Handling"): the full URL, the host decoded from punycode,
//!   and warnings. Building it does no I/O (it takes no `Io`); the page is
//!   never prefetched, and the host opens it in the system browser only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const protocol = @import("../protocol/root.zig");
const schema = @import("../schema/root.zig");

const M = protocol.messages;

pub const Option = struct { value: []const u8, label: []const u8 };

pub const StringFormat = enum { email, uri, date, date_time };

pub const FormField = struct {
    key: []const u8,
    title: []const u8,
    description: ?[]const u8 = null,
    required: bool,
    kind: Kind,
    default: ?Value = null,

    pub const Kind = union(enum) {
        string: struct { min_len: ?u32 = null, max_len: ?u32 = null, pattern: ?[]const u8 = null, format: ?StringFormat = null },
        number: struct { integer: bool, min: ?f64 = null, max: ?f64 = null },
        boolean,
        single_select: []const Option,
        multi_select: struct { options: []const Option, min: ?u32 = null, max: ?u32 = null },
    };
};

pub const FormError = error{ NotFormMode, UnsupportedSchema, OutOfMemory };

/// Keywords that describe a field without changing its shape.
const annotation_keys = [_][]const u8{ "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly", "$comment", "enumNames" };

pub const FormModel = struct {
    arena_state: std.heap.ArenaAllocator,
    message: []const u8,
    fields: []const FormField,
    schema: *schema.Schema,

    pub fn deinit(m: *FormModel) void {
        m.schema.deinit();
        m.arena_state.deinit();
    }

    /// Compiles a form-mode request. The model copies what it keeps.
    pub fn fromRequest(gpa: Allocator, p: M.ElicitParams) FormError!FormModel {
        if (p.kind() != .form) return error.NotFormMode;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena_state.deinit();
        const a = arena_state.allocator();
        const root = p.requested_schema orelse return error.UnsupportedSchema;
        if (root != .object) return error.UnsupportedSchema;
        try allowOnly(root.object, &.{ "type", "properties", "required", "$schema", "title", "description" });
        if (!isString(root.object.get("type"), "object")) return error.UnsupportedSchema;

        var required: std.StringArrayHashMapUnmanaged(void) = .empty;
        if (root.object.get("required")) |r| {
            if (r != .array) return error.UnsupportedSchema;
            for (r.array.items) |x| {
                if (x != .string) return error.UnsupportedSchema;
                try required.put(a, x.string, {});
            }
        }
        var fields: std.ArrayList(FormField) = .empty;
        if (root.object.get("properties")) |props| {
            if (props != .object) return error.UnsupportedSchema;
            var it = props.object.iterator();
            while (it.next()) |e| {
                const key = try a.dupe(u8, e.key_ptr.*);
                try fields.append(a, try compileField(a, key, e.value_ptr.*, required.contains(key)));
            }
        }
        for (required.keys()) |k| {
            for (fields.items) |f| {
                if (std.mem.eql(u8, f.key, k)) break;
            } else return error.UnsupportedSchema;
        }

        // The validator gets its own copy; elicitation formats are asserted.
        const s = schema.compile(gpa, root, .{ .format_assertion = .elicitation_only }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnsupportedSchema,
        };
        errdefer s.deinit();
        // Allocate before the arena's state is copied out.
        const message = try a.dupe(u8, p.message);
        return .{ .arena_state = arena_state, .message = message, .fields = fields.items, .schema = s };
    }

    /// Whether `values` (the object the form would send) is valid; `out`
    /// collects the errors to show next to fields.
    pub fn validate(m: *const FormModel, gpa: Allocator, values: Value, out: ?*schema.Output) bool {
        return schema.validate(m.schema, gpa, values, out) catch false;
    }

    /// The initial values: every field's default (allocated in `a`).
    pub fn defaults(m: *const FormModel, a: Allocator) !Value {
        var obj: std.json.ObjectMap = .empty;
        for (m.fields) |f| if (f.default) |d| try obj.put(a, f.key, d);
        return .{ .object = obj };
    }

    /// A field looks like it asks for a secret (password, token, API or
    /// private key, card data, SSN): the UI shows a warning banner.
    pub fn looksSensitive(m: *const FormModel) bool {
        for (m.fields) |f| {
            if (sensitive(f.key) or sensitive(f.title)) return true;
        }
        return false;
    }
};

fn isString(v: ?Value, want: []const u8) bool {
    const x = v orelse return false;
    return x == .string and std.mem.eql(u8, x.string, want);
}

fn allowOnly(obj: std.json.ObjectMap, allowed: []const []const u8) FormError!void {
    var it = obj.iterator();
    outer: while (it.next()) |e| {
        for (allowed) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) continue :outer;
        for (annotation_keys) |k| if (std.mem.eql(u8, k, e.key_ptr.*)) continue :outer;
        return error.UnsupportedSchema;
    }
}

fn optU32(v: ?Value) FormError!?u32 {
    const x = v orelse return null;
    if (x != .integer or x.integer < 0 or x.integer > std.math.maxInt(u32)) return error.UnsupportedSchema;
    return @intCast(x.integer);
}

fn optF64(v: ?Value) FormError!?f64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.UnsupportedSchema,
    };
}

fn optStr(a: Allocator, v: ?Value) FormError!?[]const u8 {
    const x = v orelse return null;
    if (x != .string) return error.UnsupportedSchema;
    return try a.dupe(u8, x.string);
}

/// `enum` (labels from the legacy `enumNames`) or `oneOf`/`anyOf` of
/// `{const, title}`.
fn options(a: Allocator, obj: std.json.ObjectMap, list_key: []const u8) FormError!?[]const Option {
    if (obj.get("enum")) |en| {
        if (en != .array or en.array.items.len == 0) return error.UnsupportedSchema;
        const names = obj.get("enumNames");
        if (names) |n| if (n != .array or n.array.items.len != en.array.items.len) return error.UnsupportedSchema;
        const out = try a.alloc(Option, en.array.items.len);
        for (en.array.items, out, 0..) |x, *o, i| {
            if (x != .string) return error.UnsupportedSchema;
            const label = if (names) |n| n.array.items[i] else x;
            if (label != .string) return error.UnsupportedSchema;
            o.* = .{ .value = try a.dupe(u8, x.string), .label = try a.dupe(u8, label.string) };
        }
        return out;
    }
    const list = obj.get(list_key) orelse return null;
    if (list != .array or list.array.items.len == 0) return error.UnsupportedSchema;
    const out = try a.alloc(Option, list.array.items.len);
    for (list.array.items, out) |x, *o| {
        if (x != .object) return error.UnsupportedSchema;
        try allowOnly(x.object, &.{"const"});
        const c = x.object.get("const") orelse return error.UnsupportedSchema;
        if (c != .string) return error.UnsupportedSchema;
        const t = x.object.get("title") orelse c;
        if (t != .string) return error.UnsupportedSchema;
        o.* = .{ .value = try a.dupe(u8, c.string), .label = try a.dupe(u8, t.string) };
    }
    return out;
}

fn compileField(a: Allocator, key: []const u8, v: Value, required: bool) FormError!FormField {
    if (v != .object) return error.UnsupportedSchema;
    const obj = v.object;
    const t = obj.get("type") orelse return error.UnsupportedSchema;
    if (t != .string) return error.UnsupportedSchema;
    var f: FormField = .{
        .key = key,
        .title = (try optStr(a, obj.get("title"))) orelse key,
        .description = try optStr(a, obj.get("description")),
        .required = required,
        .kind = .boolean,
        .default = if (obj.get("default")) |d| try cloneValue(a, d) else null,
    };
    const ty = t.string;
    if (std.mem.eql(u8, ty, "string")) {
        if (try options(a, obj, "oneOf")) |opts| {
            try allowOnly(obj, &.{ "type", "enum", "oneOf" });
            f.kind = .{ .single_select = opts };
        } else {
            try allowOnly(obj, &.{ "type", "minLength", "maxLength", "pattern", "format" });
            const format: ?StringFormat = if (obj.get("format")) |fm| blk: {
                if (fm != .string) return error.UnsupportedSchema;
                const map = [_]struct { []const u8, StringFormat }{ .{ "email", .email }, .{ "uri", .uri }, .{ "date", .date }, .{ "date-time", .date_time } };
                for (map) |m| if (std.mem.eql(u8, m[0], fm.string)) break :blk m[1];
                return error.UnsupportedSchema;
            } else null;
            f.kind = .{ .string = .{ .min_len = try optU32(obj.get("minLength")), .max_len = try optU32(obj.get("maxLength")), .pattern = try optStr(a, obj.get("pattern")), .format = format } };
        }
    } else if (std.mem.eql(u8, ty, "number") or std.mem.eql(u8, ty, "integer")) {
        try allowOnly(obj, &.{ "type", "minimum", "maximum" });
        f.kind = .{ .number = .{ .integer = ty[0] == 'i', .min = try optF64(obj.get("minimum")), .max = try optF64(obj.get("maximum")) } };
    } else if (std.mem.eql(u8, ty, "boolean")) {
        try allowOnly(obj, &.{"type"});
        f.kind = .boolean;
    } else if (std.mem.eql(u8, ty, "array")) {
        try allowOnly(obj, &.{ "type", "items", "minItems", "maxItems", "uniqueItems" });
        const items = obj.get("items") orelse return error.UnsupportedSchema;
        if (items != .object) return error.UnsupportedSchema;
        if (items.object.get("type")) |it| if (!isString(it, "string")) return error.UnsupportedSchema;
        try allowOnly(items.object, &.{ "type", "enum", "anyOf" });
        const opts = (try options(a, items.object, "anyOf")) orelse return error.UnsupportedSchema;
        f.kind = .{ .multi_select = .{ .options = opts, .min = try optU32(obj.get("minItems")), .max = try optU32(obj.get("maxItems")) } };
    } else return error.UnsupportedSchema;
    return f;
}

fn cloneValue(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out: std.json.Array = .init(a);
            for (arr.items) |x| try out.append(try cloneValue(a, x));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: std.json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |e| try out.put(a, try a.dupe(u8, e.key_ptr.*), try cloneValue(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
        else => v,
    };
}

/// `pass(word)?|secret|token|api key|private key|credit|cvv`, ignoring case
/// and separators, or the word "ssn".
fn sensitive(text: []const u8) bool {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        if (c == '_' or c == '-' or c == ' ') continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    const flat = buf[0..n];
    for ([_][]const u8{ "pass", "secret", "token", "apikey", "privatekey", "credit", "cvv" }) |w| {
        if (std.mem.indexOf(u8, flat, w) != null) return true;
    }
    var it = std.mem.tokenizeAny(u8, text, " _-.");
    while (it.next()) |word| if (std.ascii.eqlIgnoreCase(word, "ssn")) return true;
    return false;
}

// ------------------------------------------------------------------ URL

pub const UrlWarning = enum { not_https, punycode, ip_literal, userinfo_present, very_long, mixed_scripts };

pub const UrlError = error{ InvalidUrl, UnsupportedScheme, OutOfMemory };

/// URLs longer than this are flagged.
pub const long_url = 2048;

pub const UrlConsent = struct {
    full_url: []const u8,
    scheme: []const u8,
    /// The host for display: punycode labels decoded.
    host_display: []const u8,
    /// The last labels of the host (`example.co.uk`), to highlight.
    registrable_hint: []const u8,
    warnings: []const UrlWarning,

    /// Parses `url` (only `http` and `https` may be opened). No I/O.
    pub fn fromRequest(a: Allocator, url: []const u8) UrlError!UrlConsent {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        const scheme = try std.ascii.allocLowerString(a, uri.scheme);
        if (!std.mem.eql(u8, scheme, "https") and !std.mem.eql(u8, scheme, "http")) return error.UnsupportedScheme;
        const host_c = uri.host orelse return error.InvalidUrl;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const raw_host = host_c.toRaw(&host_buf) catch return error.InvalidUrl;
        const host = try std.ascii.allocLowerString(a, raw_host);
        if (host.len == 0) return error.InvalidUrl;

        var warnings: std.ArrayList(UrlWarning) = .empty;
        if (!std.mem.eql(u8, scheme, "https")) try warnings.append(a, .not_https);
        if (uri.user != null or uri.password != null) try warnings.append(a, .userinfo_present);
        const ip = host[0] == '[' or isIpv4(host);
        if (ip) try warnings.append(a, .ip_literal);
        if (url.len > long_url) try warnings.append(a, .very_long);

        // Decode punycode labels for display.
        var display: std.ArrayList(u8) = .empty;
        var puny = false;
        var mixed = false;
        var labels = std.mem.splitScalar(u8, host, '.');
        var first = true;
        while (labels.next()) |label| {
            if (!first) try display.append(a, '.');
            first = false;
            if (!ip and std.mem.startsWith(u8, label, "xn--")) {
                puny = true;
                const decoded = punycodeDecode(a, label[4..]) catch {
                    try display.appendSlice(a, label);
                    continue;
                };
                if (mixedScripts(decoded)) mixed = true;
                try display.appendSlice(a, decoded);
            } else try display.appendSlice(a, label);
        }
        if (puny) try warnings.append(a, .punycode);
        if (mixed) try warnings.append(a, .mixed_scripts);

        return .{
            .full_url = try a.dupe(u8, url),
            .scheme = scheme,
            .host_display = display.items,
            .registrable_hint = if (ip) display.items else registrable(display.items),
            .warnings = warnings.items,
        };
    }

    pub fn has(c: *const UrlConsent, w: UrlWarning) bool {
        return std.mem.indexOfScalar(UrlWarning, c.warnings, w) != null;
    }
};

fn isIpv4(host: []const u8) bool {
    var parts = std.mem.splitScalar(u8, host, '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) {
        if (p.len == 0 or p.len > 3) return false;
        _ = std.fmt.parseInt(u8, p, 10) catch return false;
    }
    return n == 4;
}

/// The last two labels, or three when the second-to-last looks like a
/// second-level public suffix (`co.uk`, `com.au`).
fn registrable(host: []const u8) []const u8 {
    var dots: [3]usize = undefined;
    var found: usize = 0;
    var i = host.len;
    while (i > 0 and found < 3) {
        i -= 1;
        if (host[i] == '.') {
            dots[found] = i;
            found += 1;
        }
    }
    if (found < 2) return host;
    const sld = host[dots[1] + 1 .. dots[0]];
    const tld = host[dots[0] + 1 ..];
    const second_level = tld.len == 2 and for ([_][]const u8{ "co", "com", "net", "org", "gov", "ac", "edu" }) |s| {
        if (std.mem.eql(u8, sld, s)) break true;
    } else false;
    if (second_level) return if (found == 3) host[dots[2] + 1 ..] else host;
    return host[dots[1] + 1 ..];
}

/// A label mixing ASCII letters with non-ASCII ones (`раypal`).
fn mixedScripts(label: []const u8) bool {
    var ascii = false;
    var other = false;
    for (label) |c| {
        if (std.ascii.isAlphabetic(c)) ascii = true;
        if (c >= 0x80) other = true;
    }
    return ascii and other;
}

/// RFC 3492 decoding of a label's part after `xn--`, as UTF-8.
pub fn punycodeDecode(a: Allocator, input: []const u8) ![]u8 {
    const base = 36;
    const tmin = 1;
    const tmax = 26;
    var out: std.ArrayList(u21) = .empty;
    defer out.deinit(a);
    var pos: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, input, '-')) |d| {
        for (input[0..d]) |c| {
            if (c >= 0x80) return error.InvalidPunycode;
            try out.append(a, c);
        }
        pos = d + 1;
    }
    var n: u32 = 128;
    var i: u32 = 0;
    var bias: u32 = 72;
    while (pos < input.len) {
        const old_i = i;
        var w: u32 = 1;
        var k: u32 = base;
        while (true) : (k += base) {
            if (pos >= input.len) return error.InvalidPunycode;
            const c = std.ascii.toLower(input[pos]);
            pos += 1;
            const digit: u32 = if (c >= 'a' and c <= 'z') c - 'a' else if (c >= '0' and c <= '9') c - '0' + 26 else return error.InvalidPunycode;
            i = std.math.add(u32, i, std.math.mul(u32, digit, w) catch return error.InvalidPunycode) catch return error.InvalidPunycode;
            const t: u32 = if (k <= bias) tmin else if (k >= bias + tmax) tmax else k - bias;
            if (digit < t) break;
            w = std.math.mul(u32, w, base - t) catch return error.InvalidPunycode;
        }
        const len: u32 = @intCast(out.items.len + 1);
        // Adapt the bias.
        var delta = if (old_i == 0) (i - old_i) / 700 else (i - old_i) / 2;
        delta += delta / len;
        var kk: u32 = 0;
        while (delta > ((base - tmin) * tmax) / 2) : (kk += base) delta /= base - tmin;
        bias = kk + (((base - tmin + 1) * delta) / (delta + 38));
        n = std.math.add(u32, n, i / len) catch return error.InvalidPunycode;
        i %= len;
        if (n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF)) return error.InvalidPunycode;
        try out.insert(a, i, @intCast(n));
        i += 1;
    }
    var utf8: std.ArrayList(u8) = .empty;
    for (out.items) |cp| {
        var b: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(cp, &b) catch return error.InvalidPunycode;
        try utf8.appendSlice(a, b[0..l]);
    }
    return utf8.toOwnedSlice(a);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn formOf(gpa: Allocator, arena: Allocator, json: []const u8) FormError!FormModel {
    const p = protocol.codec.decodeBytes(M.ElicitParams, arena, json, .{}) catch unreachable;
    return FormModel.fromRequest(gpa, p);
}

test "elicit form: all ELICIT schema examples compile to fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The spec's form examples: a GitHub username, and contact details.
    var m1 = try formOf(testing.allocator, a,
        \\{"mode":"form","message":"Please provide your GitHub username","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}
    );
    defer m1.deinit();
    try testing.expectEqual(@as(usize, 1), m1.fields.len);
    try testing.expect(m1.fields[0].required);
    try testing.expectEqualStrings("Please provide your GitHub username", m1.message);

    var m2 = try formOf(testing.allocator, a,
        \\{"message":"Please provide your contact information","requestedSchema":{"type":"object","properties":{
        \\ "name":{"type":"string","description":"Your full name"},
        \\ "email":{"type":"string","format":"email","description":"Your email address"},
        \\ "age":{"type":"number","minimum":18,"description":"Your age"}},"required":["name","email"]}}
    );
    defer m2.deinit();
    try testing.expectEqual(@as(usize, 3), m2.fields.len);
    try testing.expectEqual(StringFormat.email, m2.fields[1].kind.string.format.?);
    try testing.expectEqual(@as(f64, 18), m2.fields[2].kind.number.min.?);
    try testing.expect(!m2.fields[2].required);

    // Every primitive kind from "Requested Schema".
    var m3 = try formOf(testing.allocator, a,
        \\{"message":"All kinds","requestedSchema":{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{
        \\ "s":{"type":"string","title":"Display Name","minLength":3,"maxLength":50,"pattern":"^[a-z]+$","default":"abc"},
        \\ "n":{"type":"integer","minimum":1,"maximum":100,"default":50},
        \\ "b":{"type":"boolean","default":false},
        \\ "e":{"type":"string","enum":["Red","Green","Blue"],"default":"Red"},
        \\ "o":{"type":"string","oneOf":[{"const":"#FF0000","title":"Red"},{"const":"#00FF00","title":"Green"}]},
        \\ "legacy":{"type":"string","enum":["#FF0000","#00FF00"],"enumNames":["Red","Green"]},
        \\ "multi":{"type":"array","minItems":1,"maxItems":2,"items":{"type":"string","enum":["Red","Green","Blue"]},"default":["Red"]},
        \\ "multi2":{"type":"array","items":{"anyOf":[{"const":"#FF0000","title":"Red"},{"const":"#0000FF","title":"Blue"}]}},
        \\ "d":{"type":"string","format":"date"},"dt":{"type":"string","format":"date-time"},"u":{"type":"string","format":"uri"}}}}
    );
    defer m3.deinit();
    try testing.expectEqual(@as(usize, 11), m3.fields.len);
    try testing.expectEqualStrings("Display Name", m3.fields[0].title);
    try testing.expect(m3.fields[1].kind.number.integer);
    try testing.expectEqual(FormField.Kind.boolean, m3.fields[2].kind);
    try testing.expectEqualStrings("Green", m3.fields[3].kind.single_select[1].label);
    try testing.expectEqualStrings("#00FF00", m3.fields[4].kind.single_select[1].value);
    try testing.expectEqualStrings("Green", m3.fields[5].kind.single_select[1].label);
    try testing.expectEqual(@as(u32, 2), m3.fields[6].kind.multi_select.max.?);
    try testing.expectEqualStrings("Blue", m3.fields[7].kind.multi_select.options[1].label);
    try testing.expectEqual(StringFormat.date_time, m3.fields[9].kind.string.format.?);
}

test "elicit form: nested object rejected" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{
        \\{"message":"x","requestedSchema":{"type":"object","properties":{"addr":{"type":"object","properties":{"city":{"type":"string"}}}}}}
        ,
        \\{"message":"x","requestedSchema":{"type":"object","properties":{"a":{"$ref":"#/$defs/a"}}}}
        ,
        \\{"message":"x","requestedSchema":{"type":"object","properties":{"a":{"type":"string","format":"ipv4"}}}}
        ,
        \\{"message":"x","requestedSchema":{"type":"object","properties":{"a":{"type":"array","items":{"type":"number"}}}}}
        ,
        \\{"message":"x","requestedSchema":{"type":"object","properties":{"a":{"anyOf":[{"type":"string"},{"type":"number"}]}}}}
        ,
        \\{"message":"x","requestedSchema":{"type":"object","properties":{},"required":["missing"]}}
        ,
        \\{"message":"x","requestedSchema":{"type":"array"}}
        ,
        \\{"message":"x"}
    }) |json| try testing.expectError(error.UnsupportedSchema, formOf(testing.allocator, a, json));
    try testing.expectError(error.NotFormMode, formOf(testing.allocator, a,
        \\{"mode":"url","message":"x","url":"https://example.com"}
    ));
}

test "elicit form: defaults prefilled" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var m = try formOf(testing.allocator, a,
        \\{"message":"x","requestedSchema":{"type":"object","properties":{"n":{"type":"integer","default":5},"s":{"type":"string"},"c":{"type":"array","items":{"enum":["a","b"]},"default":["b"]}}}}
    );
    defer m.deinit();
    const d = try m.defaults(a);
    try testing.expectEqual(@as(i64, 5), d.object.get("n").?.integer);
    try testing.expect(d.object.get("s") == null);
    try testing.expectEqualStrings("b", d.object.get("c").?.array.items[0].string);
    try testing.expect(m.validate(testing.allocator, d, null));
}

test "elicit form: email/date formats asserted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var m = try formOf(testing.allocator, a,
        \\{"message":"x","requestedSchema":{"type":"object","properties":{"email":{"type":"string","format":"email"},"day":{"type":"string","format":"date"},"age":{"type":"integer","minimum":18}},"required":["email"]}}
    );
    defer m.deinit();
    const good = try protocol.codec.parseValue(a, "{\"email\":\"ada@example.com\",\"day\":\"2026-07-28\",\"age\":30}");
    try testing.expect(m.validate(testing.allocator, good, null));
    for ([_][]const u8{
        "{\"email\":\"not an email\"}",
        "{\"email\":\"ada@example.com\",\"day\":\"28/07/2026\"}",
        "{\"email\":\"ada@example.com\",\"age\":12}",
        "{\"day\":\"2026-07-28\"}",
    }) |json| {
        var out: schema.Output = .init(testing.allocator);
        defer out.deinit();
        try testing.expect(!m.validate(testing.allocator, try protocol.codec.parseValue(a, json), &out));
    }
}

test "elicit form: sensitive heuristic" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "password", "Passwd", "client_secret", "accessToken", "API Key", "api-key", "private_key", "credit_card", "CVV", "ssn" }) |key| {
        const json = try std.fmt.allocPrint(a, "{{\"message\":\"x\",\"requestedSchema\":{{\"type\":\"object\",\"properties\":{{\"{s}\":{{\"type\":\"string\"}}}}}}}}", .{key});
        var m = try formOf(testing.allocator, a, json);
        defer m.deinit();
        try testing.expect(m.looksSensitive());
    }
    for ([_][]const u8{ "name", "className", "email", "city" }) |key| {
        const json = try std.fmt.allocPrint(a, "{{\"message\":\"x\",\"requestedSchema\":{{\"type\":\"object\",\"properties\":{{\"{s}\":{{\"type\":\"string\"}}}}}}}}", .{key});
        var m = try formOf(testing.allocator, a, json);
        defer m.deinit();
        try testing.expect(!m.looksSensitive());
    }
    // A sensitive title on an innocent key counts too.
    var m = try formOf(testing.allocator, a,
        \\{"message":"x","requestedSchema":{"type":"object","properties":{"k":{"type":"string","title":"Your password"}}}}
    );
    defer m.deinit();
    try testing.expect(m.looksSensitive());
}

test "url consent: punycode/ip/userinfo/http warnings" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ok = try UrlConsent.fromRequest(a, "https://mcp.example.com/connect?elicitationId=550e8400");
    try testing.expectEqual(@as(usize, 0), ok.warnings.len);
    try testing.expectEqualStrings("mcp.example.com", ok.host_display);
    try testing.expectEqualStrings("example.com", ok.registrable_hint);

    const http = try UrlConsent.fromRequest(a, "http://example.co.uk/x");
    try testing.expect(http.has(.not_https));
    try testing.expectEqualStrings("example.co.uk", http.registrable_hint);

    const ip = try UrlConsent.fromRequest(a, "https://192.168.0.1/login");
    try testing.expect(ip.has(.ip_literal));
    const ip6 = try UrlConsent.fromRequest(a, "https://[::1]:8443/");
    try testing.expect(ip6.has(.ip_literal));

    const user = try UrlConsent.fromRequest(a, "https://paypal.com@evil.example/");
    try testing.expect(user.has(.userinfo_present));
    try testing.expectEqualStrings("evil.example", user.host_display);

    // "münchen" and a Cyrillic "а" in a Latin name.
    const puny = try UrlConsent.fromRequest(a, "https://xn--mnchen-3ya.de/");
    try testing.expect(puny.has(.punycode));
    try testing.expectEqualStrings("münchen.de", puny.host_display);
    try testing.expect(puny.has(.mixed_scripts));
    const spoof = try UrlConsent.fromRequest(a, "https://xn--pypal-4ve.com/");
    try testing.expectEqualStrings("pаypal.com", spoof.host_display);

    const long = try a.alloc(u8, long_url + 1);
    @memset(long, 'a');
    @memcpy(long[0..20], "https://example.com/");
    try testing.expect((try UrlConsent.fromRequest(a, long)).has(.very_long));

    try testing.expectError(error.UnsupportedScheme, UrlConsent.fromRequest(a, "javascript:alert(1)"));
    try testing.expectError(error.UnsupportedScheme, UrlConsent.fromRequest(a, "file:///etc/passwd"));
    try testing.expectError(error.InvalidUrl, UrlConsent.fromRequest(a, "not a url"));
}

test "url consent: no network access during construction" {
    // `fromRequest` takes no `Io`, so it cannot open a connection or
    // prefetch; this pins that signature.
    const Fn = @TypeOf(UrlConsent.fromRequest);
    const params = @typeInfo(Fn).@"fn".params;
    inline for (params) |p| try testing.expect(p.type != std.Io);
    try testing.expectEqual(@as(usize, 2), params.len);
}

test "punycode: RFC 3492 samples" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("bücher", try punycodeDecode(a, "bcher-kva"));
    try testing.expectEqualStrings("他们为什么不说中文", try punycodeDecode(a, "ihqwcrb4cv8a8dqg056pqjye"));
    try testing.expectError(error.InvalidPunycode, punycodeDecode(a, "!!"));
}
